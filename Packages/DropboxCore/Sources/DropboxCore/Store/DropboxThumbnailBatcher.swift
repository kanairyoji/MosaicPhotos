#if canImport(UIKit)
import Foundation
import ImageCacheKit
import MosaicSupport
import UIKit

/// Dropbox サムネイルのオンデマンド取得をバッチにまとめて `get_thumbnail_batch` API
/// （最大25枚/リクエスト）で一括取得する。`DropboxPhotoStore` から分離した並行処理ユニット。
///
/// 設計の要点：
/// - **2 段優先キュー**：可視セル要求（`thumbnail(for:)`・待機者あり）を**最優先(FIFO)**、
///   先読み（`prefetch(_:)`・待機者なし）を**低優先(LIFO・上限つき)**で別プールに持つ。各ウェーブは
///   可視→先読みの順でチャンクを埋めるため、表示中のセルが先読みの行列に埋もれて待たされない。
/// - **先読みのキャンセル**：スクロールで画面外へ出た先読みは `cancelPrefetch(_:)` で**取得前に破棄**し、
///   見えていないサムネのネットワーク取得を止める（行列が深くならない）。
/// - **キャッシュ済みは積まない**：先読みはメモリ/ディスクに既にあるものを `thumbnailExists` で除外し、
///   無駄なネットワーク取得を避ける。
/// - **churn 耐性**：可視要求の Task がセル再描画でキャンセルされても、待機者だけ解放しフェッチは継続して
///   キャッシュへ書く（churn が収まれば即ヒット）。
/// - **背景処理へ譲る**：ドレイン稼働中は `BackgroundActivityMonitor.cloudThumbnailBusy` を立て、
///   CLIP 背景埋め込みに CPU を譲らせる。
@MainActor
final class DropboxThumbnailBatcher {
    private let apiClient: DropboxAPIClient
    private let cache: DropboxCacheStore
    /// バッチ集約のデバウンス時間。テストでは短縮して決定性を上げる。
    private let debounceNs: UInt64
    /// 1 リクエストあたりの最大件数。テストでは小さくしてチャンク分割を検証する。
    private let chunkSize: Int
    /// バッチリクエストの同時実行数（並行ドレイン）。設定で変更可（常識的範囲にクランプ）。
    private var maxConcurrentRequests: Int

    /// 可視セルが要求中のサムネ（待機者あり・最優先）。path で重複排除。
    private var pendingVisible: [String: DropboxFileItem] = [:]
    /// 先読み（待機者なし・低優先・LIFO）。挿入順を `prefetchOrder`（古い→新しい）で保持し、
    /// drain は末尾（最新）から取り出す。上限超過は古い順に破棄する。
    private var prefetchItems: [String: DropboxFileItem] = [:]
    private var prefetchOrder: [String] = []
    /// 先読みの上限（超過分は古い順に破棄）。無制限に積むと行列が深くなり待ちが伸びる。
    private let maxPrefetchBacklog = 600
    /// 取得中のパス（同一パスの二重フェッチを防ぐ）。
    private var inFlight: Set<String> = []

    /// トークン単位の待機者。キャンセル時はこのトークン分のみ解放する。
    private var thumbnailWaiters: [UUID: (path: String, continuation: CheckedContinuation<UIImage?, Never>)] = [:]
    private var batchDebounceTask: Task<Void, Never>?
    /// ドレイン中フラグ。多重起動を防ぐ（pending は走行中のドレインが拾う）。
    private var isDraining = false

    init(
        apiClient: DropboxAPIClient,
        cache: DropboxCacheStore,
        debounceNs: UInt64 = DropboxInternalConstants.thumbnailBatchDebounceNs,
        chunkSize: Int = DropboxInternalConstants.thumbnailBatchChunkSize,
        maxConcurrentRequests: Int = DropboxInternalConstants.maxConcurrentThumbnailRequests
    ) {
        self.apiClient = apiClient
        self.cache = cache
        self.debounceNs = debounceNs
        self.chunkSize = chunkSize
        self.maxConcurrentRequests = DropboxThumbnailSettings.clampConcurrency(maxConcurrentRequests)
        DropboxActivityMonitor.shared.setThumbnailCapacity(self.maxConcurrentRequests)
    }

    /// 同時バッチ数を変更する（常識的範囲にクランプ）。設定変更時に呼ぶ。
    func setMaxConcurrentRequests(_ value: Int) {
        maxConcurrentRequests = DropboxThumbnailSettings.clampConcurrency(value)
        DropboxActivityMonitor.shared.setThumbnailCapacity(maxConcurrentRequests)
    }

    // MARK: - Public API

    /// サムネイルを返す。キャッシュヒット時は即返し、ミス時は**可視（最優先）**プールへ積んで取得する。
    ///
    /// 呼び出し元 Task のキャンセルでは待機者だけを解放し、フェッチ自体は中断しない。
    func thumbnail(for item: DropboxFileItem) async -> UIImage? {
        if let cached = await cache.thumbnail(for: item.path) {
            PerfTrace.count("thumb.cacheHit")
            return cached
        }
        PerfTrace.count("thumb.cacheMiss")
        let token = UUID()
        let t0 = PerfTrace.nowNs()   // 計測: ミス時の待ち時間（バッチ集約→ネット→デコードまで）
        let image = await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                thumbnailWaiters[token] = (item.path, cont)
                enqueueVisible(item)
                updatePendingActivity()
                scheduleBatchFlushIfNeeded()
            }
        } onCancel: {
            // キャンセルされた待機者のみ nil で解放する。pending は残し、バッチ完走でキャッシュへ書く。
            Task { @MainActor [weak self] in
                self?.cancelWaiter(token: token)
            }
        }
        PerfTrace.count("thumb.missWaitMs", value: PerfTrace.msSince(t0))
        return image
    }

    /// スクロール先サムネイルの**先読み**。待機者を作らず低優先プールへ積む（結果はキャッシュに乗る）。
    /// キャッシュ済み・取得中・可視要求中のものは積まない。
    func prefetch(_ items: [DropboxFileItem]) {
        Task { [weak self] in
            guard let self else { return }
            for item in items {
                let path = item.path
                if pendingVisible[path] != nil || inFlight.contains(path) { continue }
                if await cache.thumbnailExists(for: path) { continue }   // メモリ/ディスクにあれば不要
                enqueuePrefetch(item)
            }
            updatePendingActivity()
            scheduleBatchFlushIfNeeded()
        }
    }

    /// 画面外へスクロールした先読みの取得を**取り消す**（可視要求・取得中のものは触らない）。
    func cancelPrefetch(_ items: [DropboxFileItem]) {
        for item in items { removePrefetch(item.path) }
        updatePendingActivity()
    }

    // MARK: - Queue helpers

    private func enqueueVisible(_ item: DropboxFileItem) {
        let path = item.path
        removePrefetch(path)                 // 先読みプールから可視へ昇格
        if inFlight.contains(path) { return } // 取得中なら待機者だけで足りる（完了時に配送）
        pendingVisible[path] = item
    }

    private func enqueuePrefetch(_ item: DropboxFileItem) {
        let path = item.path
        if prefetchItems[path] != nil {
            // 既に積まれている → 末尾（最新）へ移動して優先度を上げる。
            if let i = prefetchOrder.firstIndex(of: path) { prefetchOrder.remove(at: i) }
            prefetchOrder.append(path)
            return
        }
        prefetchItems[path] = item
        prefetchOrder.append(path)
        while prefetchOrder.count > maxPrefetchBacklog {   // 上限超過は古い順に破棄
            let old = prefetchOrder.removeFirst()
            prefetchItems[old] = nil
        }
    }

    private func removePrefetch(_ path: String) {
        if prefetchItems.removeValue(forKey: path) != nil,
           let i = prefetchOrder.firstIndex(of: path) {
            prefetchOrder.remove(at: i)
        }
    }

    private func updatePendingActivity() {
        DropboxActivityMonitor.shared.setThumbnailPending(pendingVisible.count + prefetchItems.count)
    }

    private func cancelWaiter(token: UUID) {
        if let waiter = thumbnailWaiters.removeValue(forKey: token) {
            waiter.continuation.resume(returning: nil)
        }
    }

    /// 指定パスを待つすべての待機者へ画像を配送する。待機者が居なくても安全（先読み＝何もしない）。
    private func deliver(_ image: UIImage?, forPath path: String) {
        let tokens = thumbnailWaiters.compactMap { $0.value.path == path ? $0.key : nil }
        for token in tokens {
            if let waiter = thumbnailWaiters.removeValue(forKey: token) {
                waiter.continuation.resume(returning: image)
            }
        }
    }

    // MARK: - Draining

    private func scheduleBatchFlushIfNeeded() {
        let total = pendingVisible.count + prefetchItems.count
        if pendingVisible.count >= chunkSize || total >= chunkSize {
            startDraining()
        } else if total > 0, batchDebounceTask == nil {
            batchDebounceTask = Task { [weak self, debounceNs] in
                try? await Task.sleep(nanoseconds: debounceNs)
                guard let self, !Task.isCancelled else { return }
                self.startDraining()
            }
        }
    }

    /// ドレインを開始する。既に走っていれば何もしない（pending は走行中のドレインが拾う）。
    private func startDraining() {
        batchDebounceTask?.cancel()
        batchDebounceTask = nil
        guard !isDraining else { return }
        isDraining = true
        BackgroundActivityMonitor.shared.cloudThumbnailBusy = true   // 背景 CLIP に譲らせる
        Task { await self.drain() }
    }

    /// pending を空になるまで取得する。最大 `maxConcurrentRequests` 本のバッチを並行実行し、
    /// 各ウェーブは**可視（FIFO）→ 先読み（LIFO）**の順でチャンクを埋める。
    private func drain() async {
        defer {
            isDraining = false
            DropboxActivityMonitor.shared.setThumbnailActiveSlots(0)
            BackgroundActivityMonitor.shared.cloudThumbnailBusy = false
            // 計測: 1 ドレイン分の集計（キャッシュヒット率・デコード/待ち時間など）を 1 行に。
            PerfTrace.flushCounters("thumb-drain")
        }
        while !pendingVisible.isEmpty || !prefetchItems.isEmpty {
            let wave = nextWave()
            if wave.isEmpty { break }
            DropboxActivityMonitor.shared.setThumbnailActiveSlots(wave.count)
            updatePendingActivity()
            await withTaskGroup(of: Void.self) { group in
                for chunk in wave {
                    group.addTask { [weak self] in await self?.fetchThumbnailChunk(chunk) }
                }
            }
            // ウェーブ完了後、走行中に積まれた新規 pending を次ループで拾う。
        }
    }

    /// 次のウェーブ（最大 `maxConcurrentRequests` 本・各 `chunkSize` 件）を可視優先で取り出す。
    private func nextWave() -> [[DropboxFileItem]] {
        var wave: [[DropboxFileItem]] = []
        while wave.count < maxConcurrentRequests {
            var chunk: [DropboxFileItem] = []
            while chunk.count < chunkSize {
                guard let item = takeVisible() ?? takePrefetch() else { break }
                inFlight.insert(item.path)
                chunk.append(item)
            }
            if chunk.isEmpty { break }
            wave.append(chunk)
        }
        return wave
    }

    private func takeVisible() -> DropboxFileItem? {
        guard let path = pendingVisible.keys.first else { return nil }
        return pendingVisible.removeValue(forKey: path)
    }

    private func takePrefetch() -> DropboxFileItem? {
        while let path = prefetchOrder.popLast() {           // LIFO: 直近の先読みを優先
            if let item = prefetchItems.removeValue(forKey: path) { return item }
        }
        return nil
    }

    private func fetchThumbnailChunk(_ items: [DropboxFileItem]) async {
        defer { for item in items { inFlight.remove(item.path) } }

        struct Entry: Encodable {
            let path: String
            let format: String = DropboxInternalConstants.thumbnailFormat
            let size: String = DropboxInternalConstants.thumbnailAPISize
        }
        struct BatchArg: Encodable { let entries: [Entry] }
        struct ResultEntry: Decodable {
            let tag: String
            let thumbnail: String?
            enum CodingKeys: String, CodingKey { case tag = ".tag"; case thumbnail }
        }
        struct BatchResult: Decodable { let entries: [ResultEntry] }

        guard let body = try? JSONEncoder().encode(BatchArg(entries: items.map { Entry(path: $0.path) })) else {
            items.forEach { deliver(nil, forPath: $0.path) }
            return
        }
        // 認証ヘッダ付与・POST・ステータス検証は DropboxAPIClient に委譲。
        guard let data = try? await apiClient.rpc(url: DropboxInternalConstants.getThumbnailBatchURL, jsonBody: body),
              let result = try? JSONDecoder().decode(BatchResult.self, from: data) else {
            DropboxLogger.error("fetchThumbnailChunk() batch request failed (\(items.count) items)")
            items.forEach { deliver(nil, forPath: $0.path) }
            return
        }

        // 成功エントリの base64 を取り出し、成功しなかったものは即 nil 配送。
        var decodeInputs: [(path: String, data: Data)] = []
        for (item, entry) in zip(items, result.entries) {
            if entry.tag == "success",
               let b64 = entry.thumbnail,
               let imgData = Data(base64Encoded: b64) {
                decodeInputs.append((item.path, imgData))
            } else {
                deliver(nil, forPath: item.path)
            }
        }
        // result.entries が items より少ない場合（異常系）は残りを nil で配送
        if result.entries.count < items.count {
            items.dropFirst(result.entries.count).forEach { deliver(nil, forPath: $0.path) }
        }

        // ★ base64 デコード + 画像デコード（強制）をバックグラウンドで実行し、メインの負荷を避ける。
        // 並行数はバッチ並行数（maxConcurrentThumbnailRequests）で既に有界なので、ディスクデコード用の
        // ThumbnailDecode.limiter は通さない（ディスク再デコードを待たせない＝分離）。
        // 計測: 1 チャンク分のデコード所要と件数（ネットワークは net.* で別途計測済み）。
        let tDecode = PerfTrace.nowNs()
        let decoded: [(String, SendableUIImage?)] = await Task.detached(priority: .userInitiated) {
            decodeInputs.map { input in
                let image = UIImage(data: input.data).map { $0.preparingForDisplay() ?? $0 }
                return (input.path, image.map(SendableUIImage.init))
            }
        }.value
        PerfTrace.count("thumb.decodeMs", value: PerfTrace.msSince(tDecode))
        PerfTrace.count("thumb.decodedItems", value: Double(decodeInputs.count))

        for (path, sendable) in decoded {
            let image = sendable?.image
            if let image { await cache.storeThumbnail(image, for: path) }
            deliver(image, forPath: path)
        }
        DropboxLogger.verbose("fetchThumbnailChunk() \(items.count) items in 1 request")
    }
}
#endif
