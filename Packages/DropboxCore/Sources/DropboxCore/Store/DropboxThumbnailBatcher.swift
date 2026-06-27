#if canImport(UIKit)
import Foundation
import ImageCacheKit
import UIKit

/// Dropbox サムネイルのオンデマンド取得をバッチにまとめて `get_thumbnail_batch` API
/// （最大25枚/リクエスト）で一括取得する。`DropboxPhotoStore` から分離した並行処理ユニット。
///
/// 設計の要点（初回表示崩れの修正で導入）：
/// フェッチ要求（`pendingItems`）と待機者（`thumbnailWaiters`）を分離して管理する。
/// セルが再描画・リサイクルで `.task` をキャンセルしても、フェッチ自体は中断せず結果を
/// キャッシュへ書き込む。これにより初回表示時のセル churn でサムネイルが取得されないまま
/// 破棄され、何度も開き直すまで表示されない問題を防ぐ（churn が収まった時点でキャッシュ
/// ヒットして即表示される）。
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

    /// パス単位のフェッチ対象（同一パスが複数要求されても 1 回だけフェッチ）。
    private var pendingItems: [String: DropboxFileItem] = [:]
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

    /// サムネイルを返す。キャッシュヒット時は即返し、ミス時はバッチへ積んで取得する。
    ///
    /// 呼び出し元 Task のキャンセルでは待機者だけを解放し、フェッチ自体は中断しない。
    /// フェッチ結果はキャッシュへ書き込まれるため、セルが再描画された際に即ヒットする。
    func thumbnail(for item: DropboxFileItem) async -> UIImage? {
        if let cached = await cache.thumbnail(for: item.path) {
            return cached
        }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                pendingItems[item.path] = item
                thumbnailWaiters[token] = (item.path, cont)
                DropboxActivityMonitor.shared.setThumbnailPending(pendingItems.count)
                scheduleBatchFlushIfNeeded()
            }
        } onCancel: {
            // キャンセルされた待機者のみ nil で解放する。pendingItems は残し続け、
            // バッチが完走してキャッシュへ書き込まれるようにする。
            Task { @MainActor [weak self] in
                self?.cancelWaiter(token: token)
            }
        }
    }

    // MARK: - Private

    private func cancelWaiter(token: UUID) {
        if let waiter = thumbnailWaiters.removeValue(forKey: token) {
            waiter.continuation.resume(returning: nil)
        }
    }

    /// 指定パスを待つすべての待機者へ画像を配送する。待機者が居なくても安全
    /// （画像は既にキャッシュ済みのため、何もしないだけ）。
    private func deliver(_ image: UIImage?, forPath path: String) {
        let tokens = thumbnailWaiters.compactMap { $0.value.path == path ? $0.key : nil }
        for token in tokens {
            if let waiter = thumbnailWaiters.removeValue(forKey: token) {
                waiter.continuation.resume(returning: image)
            }
        }
    }

    private func scheduleBatchFlushIfNeeded() {
        if pendingItems.count >= chunkSize {
            startDraining()
        } else if batchDebounceTask == nil {
            batchDebounceTask = Task { [weak self, debounceNs] in
                try? await Task.sleep(nanoseconds: debounceNs)
                guard let self, !Task.isCancelled else { return }
                self.startDraining()
            }
        }
    }

    /// ドレインを開始する。既に走っていれば何もしない（pendingItems は走行中のドレインが拾う）。
    private func startDraining() {
        batchDebounceTask?.cancel()
        batchDebounceTask = nil
        guard !isDraining else { return }
        isDraining = true
        Task { await self.drain() }
    }

    /// pending を空になるまで取得する。最大 `maxConcurrentRequests` 本のバッチを
    /// 並行実行し、1本完了するごとに次のチャンクを補充する（表示枚数が増えても
    /// ネットワーク往復が直列に積み上がらない）。実行中に積まれた新規要求も拾う。
    private func drain() async {
        defer {
            isDraining = false
            DropboxActivityMonitor.shared.setThumbnailActiveSlots(0)
        }
        while !pendingItems.isEmpty {
            // MainActor 上で次のウェーブ（最大 maxConcurrentRequests 本）のチャンクを取り出す。
            var wave: [[DropboxFileItem]] = []
            while wave.count < maxConcurrentRequests, !pendingItems.isEmpty {
                let chunk = Array(pendingItems.values.prefix(chunkSize))
                for item in chunk { pendingItems[item.path] = nil }
                wave.append(chunk)
            }
            // 計測: このウェーブで稼働するスロット本数と、取り出し後の残り待ち枚数。
            DropboxActivityMonitor.shared.setThumbnailActiveSlots(wave.count)
            DropboxActivityMonitor.shared.setThumbnailPending(pendingItems.count)
            // ウェーブ内のバッチを並行取得（各子はチャンクのみ参照し MainActor 状態には触れない）。
            await withTaskGroup(of: Void.self) { group in
                for chunk in wave {
                    group.addTask { [weak self] in await self?.fetchThumbnailChunk(chunk) }
                }
            }
            // ウェーブ完了後、走行中に積まれた新規 pending を次ループで拾う。
        }
    }

    private func fetchThumbnailChunk(_ items: [DropboxFileItem]) async {
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
        let decoded: [(String, SendableUIImage?)] = await Task.detached(priority: .userInitiated) {
            decodeInputs.map { input in
                let image = UIImage(data: input.data).map { $0.preparingForDisplay() ?? $0 }
                return (input.path, image.map(SendableUIImage.init))
            }
        }.value

        for (path, sendable) in decoded {
            let image = sendable?.image
            if let image { await cache.storeThumbnail(image, for: path) }
            deliver(image, forPath: path)
        }
        DropboxLogger.verbose("fetchThumbnailChunk() \(items.count) items in 1 request")
    }
}
#endif
