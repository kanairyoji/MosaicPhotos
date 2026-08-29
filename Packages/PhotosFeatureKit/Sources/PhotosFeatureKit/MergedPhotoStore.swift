#if canImport(UIKit)
import CoreLocation
import DropboxKit
import LocalPhotoKit
import MosaicSupport
import Observation
import PhotoSourceKit
import UIKit

// MARK: - Merged photo store

/// ローカル写真（LocalPhotoStore）と Dropbox（DropboxPhotoStore）を統合して表示するストア。
///
/// - `DropboxPhotoStore` は HomeView が所有し、共有 NSCache・SyncEngine を維持したまま注入される。
///   MergedPhotoStore は別インスタンスを生成しない。
/// - `LocalPhotoStore` はこのストアが内部で保有する。
/// - `items` は computed property。`localStore.items` と `dropboxStore.items` にアクセスするため、
///   どちらのストアが更新されても SwiftUI が自動的に再描画する（Observable 連鎖追跡）。
@MainActor
@Observable
public final class MergedPhotoStore {

    // @ObservationIgnored: 参照自体は変化しないため追跡不要。
    // ただし各ストアのプロパティへのアクセスは Observable 連鎖で追跡される。
    @ObservationIgnored private let dropboxStore: DropboxPhotoStore
    @ObservationIgnored private let localStore: LocalPhotoStore
    /// 非 nil の場合、Dropbox はこのパス集合のものだけを対象にする（場所アルバム等のフィルタ用）。
    /// ローカル側は注入された `localStore`（必要なら localIdentifiers で絞り込み済み）に従う。
    @ObservationIgnored private let cloudPathFilter: Set<String>?
    /// バックアップ台帳の対応（Dropbox パス小文字 → localIdentifier）を返す seam。
    /// 実体は `BackupKit`（このパッケージは BackupKit に依存しない）。アプリが結線する。
    /// 未設定なら何も隠さない＝従来どおりの表示（重複するが、消えるよりよい）。
    @ObservationIgnored public var backupCopyIndexProvider: (@Sendable () async -> [String: String])?
    /// 直近に解決したバックアップ対応表（再構築のたびに台帳を引き直さないための控え）。
    @ObservationIgnored private var backupCopyIndex: [String: String] = [:]
    /// 直近に代入した一覧の指紋（オフメインで計算）。同じなら代入しない。
    @ObservationIgnored private var lastMergedSignature: Int?

    /// 表示用の確定済み配列（描画パスは O(1) でこれを読むだけ）。
    /// merge + sort はメインアクタ外（Task.detached）で行い、完成品をここへ代入する。
    public private(set) var items: [MergedPhotoItem] = []
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    /// 再構築の世代。代入時に照合し、追い越された古い結果を捨てる。
    /// 再構築の世代（最新の結果だけを反映する・`GenerationGuard`）。
    @ObservationIgnored private var rebuildGeneration = GenerationGuard()
    /// 2-a: 再構築のデバウンス用タイマー。Dropbox 初回同期は 0.4 秒ごとに `items` を差し替えるため、
    /// 変化のたびに 68k 件の merge+sort を走らせると（off-main でも .userInitiated で）UI と競合する。
    /// 連続する変化をまとめて 1 回に集約する。
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private let rebuildDebounce: Duration = .milliseconds(400)
    /// `start()` で監視を張ったか（init では張らない・二重登録防止）。
    @ObservationIgnored private var isObserving = false

    public init(
        dropboxStore: DropboxPhotoStore,
        localStore: LocalPhotoStore? = nil,
        cloudPathFilter: Set<String>? = nil
    ) {
        self.dropboxStore = dropboxStore
        self.localStore = localStore ?? LocalPhotoStore()
        self.cloudPathFilter = cloudPathFilter
        // ⚠️ ここで observeStores() を張らないこと。監視の開始は `start()`（＝実際に画面に出たとき）まで
        // 遅らせる。SwiftUI のビューは再評価のたびに init が走るため、`State(initialValue: .forMembers(…))`
        // 方式（PlacePhotos / AutoAlbumPhotos / PersonAlbum / DeviceAlbumPhotos の 4 画面）では
        // **使い捨てのストアが大量に生まれる**。init で監視を張ると、その捨てられるはずのストアまでもが
        // localStore/dropboxStore の変化に反応して merge+sort を走らせてしまう。
        // 実機ログ（diagnostics-20）では 18 秒で 546 回の `merged.rebuild`（うち local=6 の小さなメンバー
        // ストア）が記録されていた。start() されないストアは何も監視せず、そのまま破棄される。
    }

    // MARK: - Off-main merge/sort

    /// `localStore.items` / `dropboxStore.items` の変化を Observation で監視し、
    /// 変化のたびに再構築をスケジュールする。onChange は一度きりなので毎回再登録する。
    private func observeStores() {
        withObservationTracking {
            _ = localStore.items
            _ = dropboxStore.items
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeStores()      // re-arm
                self.scheduleRebuild()    // 2-a: デバウンスして 1 回にまとめる
            }
        }
    }

    /// 2-a: 変化の連続を 1 回の再構築に集約する（トレーリングデバウンス）。
    private func scheduleRebuild() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.rebuildDebounce ?? .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.rebuildItems()
        }
    }

    /// 両ストアの配列をスナップショットし、メインアクタ外で filter + map + sort して
    /// 完成した配列をメインで代入する（68k 件規模のソートで描画を固めないため）。
    /// バックアップ台帳の対応表を取り直してから再構築する。
    /// ⚠️ 台帳の引き直しは**再構築のたびにやらない**（初回同期中は 0.4 秒ごとに再構築が走る）。
    /// 端末写真・バックアップの増減は再構築の頻度に比べてずっと遅いので、ここで一度取れば足りる。
    public func refreshBackupCopyIndex() async {
        guard let provider = backupCopyIndexProvider else { return }
        let index = await provider()
        guard index != backupCopyIndex else { return }
        backupCopyIndex = index
        rebuildItems()
    }

    func rebuildItems() {
        let localSnapshot = localStore.items                  // [LocalPhotoItem]（Sendable）
        let cloudSnapshot = dropboxStore.items                // [DropboxFileItem]（Sendable）
        let filter = cloudPathFilter
        let backupIndex = backupCopyIndex
        rebuildTask?.cancel()
        // ⚠️ **世代**を採番する。`Task.isCancelled` の確認と代入の間にキャンセルされる競合は
        // 防げないため、確認だけでは新しい結果を古いスナップショットが上書きし得る
        // （レビュー指摘）。代入側でも世代を照合して、最新の再構築だけを通す。
        let generation = rebuildGeneration.next()
        rebuildTask = Task.detached(priority: .userInitiated) { [weak self] in
            // ⚠️ 86k 件のマージ＋ソート＋指紋はメモリを積む。**札を立てて**背景の重いロードと
            // 重ならないようにする（`HeavyLoad`・diagnostics-66）。
            HeavyLoad.begin("merged.rebuild")
            defer { HeavyLoad.end("merged.rebuild") }
            let t0 = CFAbsoluteTimeGetCurrent()
            let local = localSnapshot.map(MergedPhotoItem.local)
            // ⚠️ この端末のバックアップコピーは、**端末に原本が無いときだけ**出す
            // （原本が有るのに出すと 1 枚の写真が二重に並ぶ・実機 diagnostics-57/58）。
            let hidden = BackupCopyHiding.hiddenPaths(
                backupPathToLocalID: backupIndex,
                localIdentifiers: Set(localSnapshot.map(\.id)))
            let visibleCloud = hidden.isEmpty
                ? MergedPhotoStore.filteredCloudItems(cloudSnapshot, filter: filter)
                : MergedPhotoStore.filteredCloudItems(cloudSnapshot, filter: filter)
                    .filter { !hidden.contains($0.path.lowercased()) }
            let cloud = visibleCloud.map(MergedPhotoItem.cloud)
            // グリッドは下が新しい（昇順＋ defaultScrollAnchor(.bottom)）。
            let merged = (local + cloud).sortedByCaptureDateAscending()
            if Task.isCancelled { return }
            // 指紋は**ここ（オフメイン）で**取る。メインで取ると id の文字列生成が
            // そのまま画面の停止時間になる。
            var hasher = Hasher()
            for item in merged { hasher.combine(item.id) }
            hasher.combine(merged.count)
            let signature = hasher.finalize()
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            Diagnostics.mark("merged.rebuild: local=\(local.count) cloud=\(cloud.count) "
                             + "hiddenBackupCopies=\(hidden.count) total=\(merged.count) sort=\(Int(ms))ms")
            await self?.setItems(merged, generation: generation, signature: signature)
        }
    }

    /// テスト用: その世代がまだ現行か（追い越されていないか）。
    func isCurrentRebuildGenerationForTesting(_ token: Int) -> Bool {
        rebuildGeneration.isCurrent(token)
    }

    /// 次の再構築世代を採番する（テスト用。本番は `rebuildItems` が採番する）。
    func nextRebuildGenerationForTesting() -> Int { rebuildGeneration.next() }

    /// 最新世代の結果だけを反映する（遅れて届いた古い一覧を捨てる）。
    func setItems(_ newItems: [MergedPhotoItem], generation: Int, signature: Int) {
        guard rebuildGeneration.isCurrent(generation) else {
            Diagnostics.mark("merged.rebuild: dropped stale result (gen \(generation) は追い越された)")
            return
        }
        // ⚠️ **中身が同じなら代入しない**（実機 diagnostics-59）。同期中は 0.4 秒ごとに
        // 再構築が走るが、内容は変わらないことがほとんど。代入すると配列の実体が変わり、
        // グリッドは「変わったかもしれない」として 86,000 件ぶんの ID 指紋を**メインで**
        // 取り直す（id は文字列を作り、その中で PHAsset.localIdentifier まで読む）。
        // 指紋は既にオフメインで計算済みなので、ここで突き合わせて素通しする。
        guard signature != lastMergedSignature else { return }
        lastMergedSignature = signature
        items = newItems
    }
}

// MARK: - PhotoStore conformance

extension MergedPhotoStore: PhotoStore {
    public typealias Item = MergedPhotoItem

    /// ローカル＋Dropbox の混在ソース＝フィルタの「ソース」欄（端末のみ/クラウドのみ）を出す。
    public var isMixedSource: Bool { true }

    public var state: PhotoLoadState {
        Self.resolveState(
            localState: localStore.state,
            hasLocalAssets: !localStore.assets.isEmpty,
            hasDropbox: !dropboxStore.items.isEmpty,
            dropboxBusy: dropboxBusy
        )
    }

    /// Dropbox がまだ取得中か（ロード中 or 初回同期/差分取得中）。
    /// T2: ローカルが空でも Dropbox 取得完了前に "No photos" を出さないために使う。
    private var dropboxBusy: Bool {
        if case .loading = dropboxStore.loadStatus { return true }
        switch dropboxStore.syncState {
        case .initialSync, .fetchingDelta: return true
        default: return false
        }
    }

    // MARK: - Pure helpers (テスト対象)

    /// Dropbox アイテムをパスフィルタで絞り込む。フィルタが nil なら全件。
    nonisolated static func filteredCloudItems(
        _ items: [DropboxFileItem], filter: Set<String>?
    ) -> [DropboxFileItem] {
        guard let filter else { return items }
        return items.filter { filter.contains($0.path) }
    }

    /// 統合状態を解決する。ローカル権限が無い（needsSetup/failed）場合は全体をブロックし、
    /// いずれかにアイテムがあれば loaded、無ければローカルの読み込み状況に従う。
    nonisolated static func resolveState(
        localState: PhotoLoadState, hasLocalAssets: Bool, hasDropbox: Bool,
        dropboxBusy: Bool = false
    ) -> PhotoLoadState {
        switch localState {
        case .needsSetup, .failed:
            return localState
        default:
            break
        }
        if hasLocalAssets || hasDropbox { return .loaded }
        switch localState {
        case .idle:    return .idle
        case .loading: return .loading
        // T2: ローカルが空でも Dropbox 取得中なら empty にせず loading を維持する。
        default:       return dropboxBusy ? .loading : .empty
        }
    }

    public func start() async {
        // 監視はここで初めて張る（init ではなく・上の注記を参照）。多重呼び出しでも二重登録しない。
        if !isObserving {
            isObserving = true
            observeStores()
        }
        // ローカル写真の権限要求・アセット読み込み。
        await localStore.start()
        // Dropbox キャッシュから即時ロード（SyncEngine は HomeView が管理するため起動しない）。
        // ⚠️ 既にロード済みなら再ロードしない：cachedItems() は 67k 件を毎回 SwiftData から
        //    実体化するため、All Photos を開くたびに呼ぶと無駄が大きい（実機ログで確認）。
        //    同期で増えた分は scheduleCacheRefresh → dropboxStore.items 更新 → observeStores で
        //    自動的に再ビルドされるので、ここで取りこぼすことはない。
        if dropboxStore.items.isEmpty {
            await dropboxStore.loadItems()
        }
        // バックアップ台帳の対応表を取ってから組み立てる（二重表示の抑止に要る）。
        // 取れなくても表示は止めない＝従来どおり全部出す（重複するが、消えるよりよい）。
        await refreshBackupCopyIndex()
        // 読み込み直後に一度ビルド（Observation が取りこぼしても確実に反映）。
        rebuildItems()
    }

    public func retry() async {
        // ローカル権限拒否時に設定アプリへ誘導する。
        await localStore.retry()
    }

    /// ローカル/クラウドへ 1:1 で振り分ける共通ヘルパ。各ローディングメソッドはこれで一行化する
    /// （`switch case .local/.cloud` の繰り返しを 1 箇所に集約）。バッチ系（prefetch 等）は専用ロジック。
    private func forward<T>(_ item: MergedPhotoItem,
                            local: (LocalPhotoItem) async -> T,
                            cloud: (DropboxFileItem) async -> T) async -> T {
        switch item {
        case .local(let l): return await local(l)
        case .cloud(let c): return await cloud(c)
        }
    }

    public func thumbnail(for item: MergedPhotoItem) async -> UIImage? {
        await forward(item, local: { await localStore.thumbnail(for: $0) },
                            cloud: { await dropboxStore.thumbnail(for: $0) })
    }

    public func thumbnail(for item: MergedPhotoItem, targetSize: CGSize) async -> UIImage? {
        // Dropbox のサムネイルは API 側で固定サイズ（w128h128）のため targetSize は使わない（設計通り）。
        await forward(item, local: { await localStore.thumbnail(for: $0, targetSize: targetSize) },
                            cloud: { await dropboxStore.thumbnail(for: $0) })
    }

    /// 2段階サムネイル（プログレッシブ表示）をローカル実装へ転送する。
    /// クラウドは既定実装（単発）のまま。転送しないと default 実装が使われ、ローカルの
    /// degraded 先行・近似サイズ暫定表示が効かなくなる点に注意。
    public func thumbnailStages(for item: MergedPhotoItem, targetSize: CGSize) -> AsyncStream<UIImage> {
        switch item {
        case .local(let l): return localStore.thumbnailStages(for: l, targetSize: targetSize)
        case .cloud(let c): return dropboxStore.thumbnailStages(for: c, targetSize: targetSize)
        }
    }

    /// 先読みを local / cloud に振り分ける。既定実装（1件ずつ thumbnail）だとローカルが
    /// `PHCachingImageManager` の一括先読みを使えずスクロールが重いため、専用に分配する。
    public func prefetch(_ items: [MergedPhotoItem], targetSize: CGSize) {
        var locals: [LocalPhotoItem] = []
        var clouds: [DropboxFileItem] = []
        for item in items {
            switch item {
            case .local(let local): locals.append(local)
            case .cloud(let cloud): clouds.append(cloud)
            }
        }
        if !locals.isEmpty { localStore.prefetch(locals, targetSize: targetSize) }   // PHCachingImageManager 一括
        if !clouds.isEmpty { dropboxStore.prefetch(clouds, targetSize: targetSize) } // Dropbox バッチャに集約
    }

    /// 先読みのキャンセルを cloud に振り分ける。Dropbox は未取得の先読みをキューから破棄する。
    /// ローカルは `PHCachingImageManager` が先読み窓を自己管理するため no-op。
    public func cancelPrefetch(_ items: [MergedPhotoItem]) {
        var clouds: [DropboxFileItem] = []
        for item in items {
            if case .cloud(let cloud) = item { clouds.append(cloud) }
        }
        if !clouds.isEmpty { dropboxStore.cancelPrefetch(clouds) }
    }

    public func fullImage(for item: MergedPhotoItem) async -> UIImage? {
        await forward(item, local: { await localStore.fullImage(for: $0) },
                            cloud: { await dropboxStore.fullImage(for: $0) })
    }

    /// 共有用の原本は、それぞれのストアの実装へ委譲する。
    public func originalForSharing(_ item: MergedPhotoItem) async -> SharedOriginal? {
        await forward(item, local: { await localStore.originalForSharing($0) },
                            cloud: { await dropboxStore.originalForSharing($0) })
    }

    public func location(for item: MergedPhotoItem) async -> CLLocationCoordinate2D? {
        await forward(item, local: { await localStore.location(for: $0) },
                            cloud: { await dropboxStore.location(for: $0) })
    }

    public func cachedLocation(for item: MergedPhotoItem) async -> CLLocationCoordinate2D? {
        await forward(item, local: { await localStore.cachedLocation(for: $0) },
                            cloud: { await dropboxStore.cachedLocation(for: $0) })
    }

    public func prefetchFullImage(for item: MergedPhotoItem) {
        // クラウドのみ先読み（ローカルは PHImageManager が高速で不要）。
        if case .cloud(let cloud) = item { dropboxStore.prefetchFullImage(for: cloud) }
    }

    public func setFavorite(_ item: MergedPhotoItem, _ isFavorite: Bool) async -> Bool {
        // クラウドのお気に入りはアプリ側で永続する（ADR-67）。以前は常に false を返しており、
        // 統合ビューではクラウド写真をお気に入りにできなかった。
        let ok = await forward(item, local: { await localStore.setFavorite($0, isFavorite) },
                                     cloud: { await dropboxStore.setFavorite($0, isFavorite) })
        // 統合リスト側の該当 1 件だけ刻印し直す（グリッドのハートを即時更新）。
        // ⚠️ `rebuildItems()` は 68k 件の再ソートなので、1 件のトグルでは呼ばない。
        if ok, case .cloud(let cloud) = item,
           let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = .cloud(cloud.withFavorite(isFavorite))
        }
        return ok
    }

    public func metadata(for item: MergedPhotoItem) async -> PhotoExifInfo? {
        await forward(item, local: { await localStore.metadata(for: $0) },
                            cloud: { await dropboxStore.metadata(for: $0) })
    }
}
#endif
