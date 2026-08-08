import AutoAlbumCore
import CoreGraphics
import Photos

// 知覚プロバイダ（CLIP 埋め込み・Vision タグ）の画像ロードを並列化する共通ヘルパ。
//
// ⚠️ 従来は各プロバイダが `for refKey { await loadLocalCGImage(...) }` と**1枚ずつ直列**に
//    ロードしていた。ANE のバッチ推論に対して画像ロード（PHImageManager のデコード／Dropbox
//    サムネ取得）が直列のボトルネックになっていたため、ミニバッチ内は同時 `maxConcurrent` 件まで
//    並列にロードしてから推論へ渡す（候補A）。同時数は 1024px でも数十 MB に収まる範囲。

/// refKey（ローカル/クラウド）→ CGImage。ローカルは PHImageManager、クラウドは注入ローダ。
nonisolated func loadRefCGImage(_ refKey: String, maxPixel: CGFloat,
                                cloudImage: @Sendable (String) async -> CGImage?) async -> CGImage? {
    guard let ref = PhotoRef.decode(refKey) else { return nil }
    if let localId = ref.localIdentifier {
        // renderFloor 既定（向き安全）。CLIP/顔検出の入力互換のため loadLocalCGImage 経由。
        return await loadLocalCGImage(localId, maxPixel: maxPixel)
    }
    if let path = ref.cloudPath { return await cloudImage(path) }
    return nil
}

/// keys を**同時 maxConcurrent 件**まで並列に `body` へ通し、key→結果の辞書を返す（nil は欠落）。
/// 画像ロード＋Vision 一括パスのような「ロードと推論を1関数で行う」経路の並列化に使う（候補A/C）。
nonisolated func boundedConcurrentResults<T: Sendable>(
    _ keys: [String], maxConcurrent: Int = 4,
    _ body: @Sendable @escaping (String) async -> T?) async -> [String: T] {
    guard !keys.isEmpty else { return [:] }
    let limit = max(1, maxConcurrent)
    return await withTaskGroup(of: (String, T?).self) { group in
        var iterator = keys.makeIterator()
        func addNext() -> Bool {
            guard let key = iterator.next() else { return false }
            group.addTask { (key, await body(key)) }
            return true
        }
        var started = 0
        while started < limit && addNext() { started += 1 }
        var out: [String: T] = [:]
        out.reserveCapacity(keys.count)
        for await (key, value) in group {
            if let value { out[key] = value }
            _ = addNext()
        }
        return out
    }
}

/// refKeys を**同時 maxConcurrent 件**までロードして refKey→CGImage の辞書を返す（取得不可は欠落）。
/// 入力順は呼び出し側が refKeys を辿ることで復元する。
nonisolated func loadRefImages(_ refKeys: [String], maxPixel: CGFloat,
                               cloudImage: @escaping @Sendable (String) async -> CGImage?,
                               maxConcurrent: Int = 4) async -> [String: CGImage] {
    guard !refKeys.isEmpty else { return [:] }
    let limit = max(1, maxConcurrent)
    return await withTaskGroup(of: (String, CGImage?).self) { group in
        var iterator = refKeys.makeIterator()
        func addNext() -> Bool {
            guard let key = iterator.next() else { return false }
            group.addTask { (key, await loadRefCGImage(key, maxPixel: maxPixel, cloudImage: cloudImage)) }
            return true
        }
        var started = 0
        while started < limit && addNext() { started += 1 }

        var out: [String: CGImage] = [:]
        out.reserveCapacity(refKeys.count)
        for await (key, cg) in group {
            if let cg { out[key] = cg }
            _ = addNext()   // 1 件完了ごとに次を投入し、常に最大 limit 件を並走させる
        }
        return out
    }
}

/// refKey 群からクラウド path を抜き出し、**一括の先行取得**を依頼する（ADR-83）。
///
/// クラウド写真は 1 枚ずつサムネを取ると 1 枚 600〜800ms の往復が推論と直列に並び、
/// AI 処理時間の 85〜90% をダウンロード待ちが占めていた（実測 diagnostics-31/32）。
/// バッチ単位でまとめて要求すると Dropbox のバッチ API（25 枚/リクエスト・並列）に相乗りでき、
/// 2 枚目以降は取得済みから始まる。ローカル（"L-…"）は何もしない（PHImageManager は十分速い）。
/// `warm` は**即座に返る**実装であること（実際の取得は非同期）。
nonisolated func warmCloudPaths(_ refKeys: [String], using warm: (@Sendable ([String]) -> Void)?) {
    guard let warm else { return }
    let paths = refKeys.compactMap { PhotoRef.decode($0)?.cloudPath }
    guard !paths.isEmpty else { return }
    warm(paths)
}
