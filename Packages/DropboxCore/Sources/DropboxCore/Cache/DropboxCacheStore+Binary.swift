#if canImport(UIKit)
import Foundation
import ImageCacheKit
import MosaicSupport
import UIKit

/// `DropboxCacheStore` のバイナリ（サムネイル／フル画像）取得・保存レイヤー。
/// ディスク I/O・JPEG エンコード・強制デコードは detached タスク（actor 外・並列）で行い、
/// 使用量記録（`DropboxCacheStore+Eviction.swift`）だけ actor に戻す。
extension DropboxCacheStore {

    // MARK: - Thumbnail cache (memory → disk)

    /// サムネイルを返す。メモリヒットは即返し、ミス時は**ディスク読み込み＋強制デコードを
    /// detached タスク（actor 外・並列）**で行い、結果をスレッドセーフな `NSCache` に入れて取り出す。
    /// デコード済み画像のみが境界を跨ぐため Sendable 問題を避けられ、actor をブロックしない。
    /// メモリ層のみの即答（actor hop なし・`thumbnailMemory` は Sendable な NSCache ラッパ）。
    /// 可視セルのヒット経路から actor キュー待ちを外すための fast path。
    nonisolated func cachedThumbnail(for path: String) -> UIImage? {
        thumbnailMemory.image(forKey: path)
    }

    func thumbnail(for path: String) async -> UIImage? {
        if let cached = thumbnailMemory.image(forKey: path) {
            PerfTrace.count("cache.thumb.memHit")
            return cached
        }
        let name = DropboxCacheNaming.fileName(kind: .thumbnail, path: path)
        let store = thumbnailStore
        let memory = thumbnailMemory
        let t0 = PerfTrace.nowNs()   // 計測: デコード順番待ちの所要（queueMs）
        // デコード同時数を制限（要求ごとの無制限 detached でスレッド過多→CPU 競合で激遅になるのを防ぐ）。
        await ThumbnailDecode.limiter.acquire()
        PerfTrace.count("cache.thumb.queueMs", value: PerfTrace.msSince(t0))
        // ★ T2: スクラブで画面外へ消えたセルの要求（キャンセル済み）はデコードせず捨てる。
        //    行列に数千件並んだとき、無効分のデコードが有効分を待たせるのを防ぐ。
        if Task.isCancelled {
            await ThumbnailDecode.limiter.release()
            PerfTrace.count("cache.thumb.cancelled")
            return nil
        }
        let t1 = PerfTrace.nowNs()   // 計測: 実デコードの所要（diskHit）
        await Task.detached(priority: .userInitiated) {
            if let decoded = store.decodedImage(forName: name) {
                memory.insertDecoded(decoded, forKey: path)   // NSCache はスレッドセーフ・実コスト計上
            }
        }.value
        await ThumbnailDecode.limiter.release()
        guard let image = thumbnailMemory.image(forKey: path) else {
            PerfTrace.count("cache.thumb.miss")   // メモリにもディスクにも無い（ネット取得が必要）
            return nil
        }
        PerfTrace.count("cache.thumb.diskHit", value: PerfTrace.msSince(t1))
        touchUsage(kind: .thumbnail, path: path)
        return image
    }

    /// サムネイルがメモリまたはディスクに存在するか（**デコードせず**安価に確認）。
    /// 先読みで「キャッシュ済みは取得不要」を判定し、無駄なネットワーク取得を防ぐ。
    func thumbnailExists(for path: String) -> Bool {
        if thumbnailMemory.image(forKey: path) != nil { return true }
        return thumbnailStore.fileExists(forName: DropboxCacheNaming.fileName(kind: .thumbnail, path: path))
    }

    func storeThumbnail(_ image: UIImage, for path: String) {
        thumbnailMemory.insertDecoded(image, forKey: path)
        let sendable = SendableUIImage(image)
        // ⚠️ 重い JPEG エンコードだけを actor 外で行い、**書き込みと記録は actor 内で
        // トークンを照合してから**行う。エンコード中に無効化（Dropbox 側の更新・
        // アカウント切替）が入ると、古い画像が復活してしまうため（レビュー指摘）。
        let token = writeToken(for: path)
        Task.detached(priority: .utility) { [weak self] in
            guard let data = sendable.image.jpegData(
                compressionQuality: DropboxInternalConstants.thumbnailJPEGQuality) else { return }
            await self?.commitBinary(kind: .thumbnail, data: data, path: path, token: token)
        }
    }

    /// ディスク書き込みは **actor の外**で行い（数 MB の I/O で actor を止めない）、
    /// その前後でトークンを照合する。
    /// - 書く前: 既に無効化されていれば何もしない（無駄な I/O を避ける）。
    /// - 書いた後: 書いている最中に無効化されていたら**書いたファイルを消す**
    ///   （記録もしない）。一瞬ファイルが存在するが、必ず収束する。
    nonisolated func commitBinary(kind: CacheUsageEntry.CacheKind, data: Data, path: String,
                                  token: WriteToken) async {
        guard await isWriteValid(token, for: path) else {
            DropboxLogger.verbose("cache: dropped stale \(kind) write for \(path)")
            return
        }
        let name = DropboxCacheNaming.fileName(kind: kind, path: path)
        // 書けなかったら使用量も記録しない（架空の使用量で LRU が暴れるのを防ぐ）。
        guard await store(for: kind).write(data, name: name) else {
            DropboxLogger.error("cache: \(kind) write failed — \(path)")
            return
        }
        await finalizeWrite(kind: kind, path: path, byteSize: data.count, token: token)
    }

    /// 書き込み後の確定（actor 内）。無効化されていたら書いた分を取り消す。
    private func finalizeWrite(kind: CacheUsageEntry.CacheKind, path: String,
                               byteSize: Int, token: WriteToken) {
        guard isWriteValid(token, for: path) else {
            DropboxLogger.verbose("cache: rolled back stale \(kind) write for \(path)")
            removeBinary(kind: kind, path: path)
            if kind == .thumbnail { thumbnailMemory.removeImage(forKey: path) }
            return
        }
        recordStored(kind: kind, path: path, byteSize: byteSize)
    }


    // MARK: - Full image cache (disk only)

    /// キャッシュ済みフル画像の生データ（EXIF を含む）を返す。EXIF 抽出に使う。
    func fullImageData(for path: String) -> Data? {
        fullImageStore.data(forName: DropboxCacheNaming.fileName(kind: .fullImage, path: path))
    }

    /// フル画像をキャッシュから返す。ディスク読み込み＋ダウンサンプル（画面相当）を
    /// バックグラウンドで行う。ビューアはズーム無しのためフル解像度デコードは不要で、
    /// 常駐・一時メモリを抑える（保存ファイルは原バイトのまま＝EXIF 保持）。
    func fullImage(for path: String) async -> UIImage? {
        let name = DropboxCacheNaming.fileName(kind: .fullImage, path: path)
        let store = fullImageStore
        let decoded = await Task.detached(priority: .userInitiated) { () -> SendableUIImage? in
            guard let data = store.data(forName: name) else { return nil }
            return (ImageDownsampling.downsample(data: data)
                ?? UIImage(data: data).map { $0.preparingForDisplay() ?? $0 })
                .map(SendableUIImage.init)
        }.value
        guard let image = decoded?.image else { return nil }
        touchUsage(kind: .fullImage, path: path)
        return image
    }

    /// フル画像を**元バイト列のまま**保存する。再エンコードしないため EXIF が保持される
    /// （EXIF 抽出はこのキャッシュ済みファイルを読む）。
    func storeFullImageData(_ data: Data, for path: String) {
        // フル画像も同じ規則で書く（取得中に無効化された分は捨てる）。書き込みは actor 外。
        let token = writeToken(for: path)
        Task.detached(priority: .utility) { [weak self] in
            await self?.commitBinary(kind: .fullImage, data: data, path: path, token: token)
        }
    }
}
#endif
