#if canImport(UIKit)
import CryptoKit
import Foundation
import ImageCacheKit
import MosaicSupport
import SwiftData
import UIKit

/// Local cache orchestrator for `DropboxPhotoStore`.
///
/// Mirrors the role of `DropboxKeychainStore` as an independent, self-contained
/// component: metadata (file list, sync cursor, cache usage bookkeeping) is
/// persisted with SwiftData, while thumbnail/full-image binaries are kept on
/// disk under `Caches/DropboxKit/` (separated by kind) with an additional
/// `NSCache` memory layer for thumbnails only.
///
/// See `Packages/DropboxKit/docs/interface.md` section 4.2 and
/// `implementation.md` section 8 for the full specification.
///
/// `actor` として実装し、SwiftData(ModelContext)・ファイル I/O・JPEG エンコード・デコードを
/// メインスレッドから切り離す。`@Model`（`CachedDropboxItem` / `DropboxSyncState` /
/// `CacheUsageEntry`）は actor 外へ漏らさず、必ず `Sendable` な値（`DropboxFileItem` /
/// `SyncStateInfo`）へ変換して返す。
///
/// 関心ごとにファイルを分割している：本体は metadata / sync state、バイナリ取得・保存は
/// `DropboxCacheStore+Binary.swift`、使用量記録・LRU 退避・容量設定・無効化は
/// `DropboxCacheStore+Eviction.swift`。extension から参照する格納プロパティ・共有ヘルパは internal。
actor DropboxCacheStore {
    private let modelContainer: ModelContainer
    let modelContext: ModelContext

    // バイナリ層は ImageCacheKit の共通プリミティブに委譲する。
    // 破棄ポリシー（LRU）は本型が SwiftData(CacheUsageEntry) で持つ（mtime ではない）。
    let thumbnailStore: DiskImageStore
    let fullImageStore: DiskImageStore
    let thumbnailMemory: MemoryImageCache
    /// T2: LRU touch のスロットル（5 分窓）と save バッチ化（50 件ごと）の状態。
    var recentTouches: [String: Date] = [:]
    var pendingTouchSaves = 0

    /// 安全弁（協調役が居ないときの暴走防止）。通常の追い出しは `CacheBudgetCoordinator`（ADR-185）。
    var thumbnailByteLimit: Int
    var fullImageByteLimit: Int
    /// 種別ごとの使用量（バイト）。起動時に台帳から 1 回集計し、以後は増減で追う
    /// （予算の判定のたびに 6.8 万行を舐めない・ADR-119）。nil＝未集計。
    var usageTotals: [CacheUsageEntry.CacheKind: Int] = [:]
    var usageTotalsLoaded = false
    /// **先読みしただけ**（まだ開いていない）本体画像のパス。予算超過時はここから先に捨てる。
    /// 永続化しない＝再起動後は全部「開いた」扱い（安全側）。
    var prefetchedFullImages: Set<String> = []
    /// 予算への参加（種別ごとに 1 つ・強参照で保持）。
    var budgetParticipants: [DropboxCacheBudgetParticipant] = []

    /// キャッシュ全体の世代（`clearAll` で進む）。進行中の保存を無効にするために使う。
    var cacheEpoch = 0
    /// パス単位の無効化回数（`invalidate(path:)` で進む）。
    var invalidationCounts: [String: Int] = [:]
    /// 無効化記録の上限。超えたら記録を捨てて全体世代を進める（安全側）。
    static let maxTrackedInvalidations = 5_000

    /// インメモリ容器の生成を直列にする錠（上の注記を参照）。
    private static let inMemoryContainerLock = NSLock()

    init(
        thumbnailByteLimit: Int = DropboxInternalConstants.defaultThumbnailByteLimit,
        fullImageByteLimit: Int = DropboxInternalConstants.defaultFullImageByteLimit,
        thumbnailMemoryCountLimit: Int = 0,
        isStoredInMemoryOnly: Bool = false
    ) {
        let schema = Schema([CachedDropboxItem.self, DropboxSyncState.self, CacheUsageEntry.self])
        // ⚠️ 名前を明示して "DropboxCache.store" を使う。
        // 名前なし ModelConfiguration は "default.store" になり、
        // BackupEngine の ModelContainer と衝突してスキーマエラーになる（過去に発生）。
        if isStoredInMemoryOnly {
            // ⚠️ インメモリ構成は**名前を変えないとプロセス内で同じストアを共有する**
            // （テストが並列に走ると別スイートの行が流れ込む・FaceStore で実際に踏んだ）。
            //
            // ⚠️ さらに**生成そのものを直列にする**。並列の Suite が同時に `ModelContainer` を
            // 作ると、まれに SwiftData（CoreData の `_generateTriggerSQL`）の中で落ちる——
            // 実機ログ調査中のテスト実行で 136 件が道連れになった（`BackupStore` でも同じ形を
            // 3 回観測している）。原因の特定ではないが、同時に作らなければ当たらない。
            // インメモリ＝テスト専用の経路なので、直列化の代償は無い。
            let memory = Self.inMemoryContainerLock.withLock { () -> ModelContainer in
                let config = ModelConfiguration(UUID().uuidString, schema: schema,
                                                isStoredInMemoryOnly: true)
                return (try? ModelContainer(for: schema, configurations: [config]))
                    ?? (try! ModelContainer(for: schema))
            }
            modelContainer = memory
        } else {
            // 壊れた/非互換ストアは削除して作り直し、それでも駄目ならインメモリへ
            // （自己修復＝MosaicSupport の共通ロジック。キャッシュは再同期で回復する）。
            modelContainer = makeResilientModelContainer(
                name: "DropboxCache", schema: schema,
                openFailedMessage: "DropboxCacheStore: 'DropboxCache' open failed; deleting store and rebuilding.",
                memoryFallbackMessage: "DropboxCacheStore: 'DropboxCache' still failing; using in-memory store.",
                log: { DropboxLogger.error($0) })
        }
        modelContext = ModelContext(modelContainer)
        // テスト用の累計（本番では読まれない）。

        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let baseURL = cachesURL.appendingPathComponent("DropboxKit", isDirectory: true)
        thumbnailStore = DiskImageStore(directory: baseURL.appendingPathComponent("thumbnails", isDirectory: true))
        fullImageStore = DiskImageStore(directory: baseURL.appendingPathComponent("fullimages", isDirectory: true))

        // ADR-185: 個別上限は安全弁（名目予算の 2 倍）に格下げ。合計は協調役が予算に収める。
        let safety = 2 * CacheBudget.nominalBytes(setting: CacheBudget.setting(),
                                                  totalCapacity: CacheBudget.volumeCapacity().total ?? 0)
        self.thumbnailByteLimit = isStoredInMemoryOnly ? thumbnailByteLimit : max(thumbnailByteLimit, safety)
        self.fullImageByteLimit = isStoredInMemoryOnly ? fullImageByteLimit : max(fullImageByteLimit, safety)
        // メモリ常駐を有界化：Dropbox サムネは固定サイズ（thumbnailAPISize＝w256h256・デコード約256KB）。
        // 実デコードサイズでコスト計上する `insertDecoded` に合わせ、件数上限＋総コスト上限を設ける。
        // ⚠️ critical 圧迫でも**全消去しない**（purgeOnCritical: false）。全消去すると閲覧中に毎回
        //    ディスクから再デコードする storm になり激重化するため、段階縮小（下限まで）に留める。
        thumbnailMemory = MemoryImageCache(
            totalCostLimit: DropboxInternalConstants.thumbnailMemoryCostLimit,
            countLimit: thumbnailMemoryCountLimit > 0 ? thumbnailMemoryCountLimit
                : DropboxInternalConstants.thumbnailMemoryCountLimit,
            purgeOnCritical: false,
            pressureFloor: DropboxInternalConstants.thumbnailMemoryPressureFloor
        )

        // サムネの API サイズ（w128h128→w256h256 等）を変更したら、旧サイズのキャッシュを
        // **一度だけ全消去**する。ファイル名（SHA256(path).jpg）にサイズが入らないため、放置すると
        // 旧 128px がそのまま使われ「ぼやけたまま」になる。LRU 削除もファイル名再計算ベースなので
        // 命名変更では旧ファイルが孤児になる＝マーカー方式が正解。消去後は再取得で自然に埋まる。
        let sizeMarkerKey = "dropboxThumbnailAPISizeCached"
        let storedSize = UserDefaults.standard.string(forKey: sizeMarkerKey)
        if storedSize != DropboxInternalConstants.thumbnailAPISize {
            // マーカー無し（nil）は「初回インストール」と「マーカー導入前の旧版からの更新（128px
            // キャッシュ持ち）」を区別できないため、**無条件でクリア**する（初回は空＝実質 no-op）。
            thumbnailStore.clear()
            if let entries = try? modelContext.fetch(FetchDescriptor<CacheUsageEntry>()) {
                for entry in entries where entry.kind == CacheUsageEntry.CacheKind.thumbnail.rawValue {
                    modelContext.delete(entry)
                }
                try? modelContext.save()
            }
            DropboxLogger.info("thumbnail API size \(storedSize ?? "(none)") → \(DropboxInternalConstants.thumbnailAPISize) — cleared thumbnail cache")
            UserDefaults.standard.set(DropboxInternalConstants.thumbnailAPISize, forKey: sizeMarkerKey)
        }
    }

    // MARK: - Metadata / sync state

    func cachedItems(accountId: String) -> [DropboxFileItem] {
        // 計測: SwiftData の全件 fetch + 値型変換の所要（起動・全件表示の重さの一因になりうる）。
        // ⚠️ **全列の実体化**を数える。表示以外の用途でここを呼ぶと 7 万行ぶんの
        //    `@Model` と値型を作ることになるので、回帰テストで検出できるようにしておく。
        PerfTrace.count("cache.itemsMaterialized")
        materializeCallsForTesting += 1
        let t0 = PerfTrace.nowNs()
        defer { PerfTrace.logSpan("cache.fetchItems", ms: PerfTrace.msSince(t0)) }
        // 並べ替えは DB 側（SQLite）で行う。捕捉日時の昇順（nil は先頭＝最古扱い）。
        // 67k 件を Swift でソートしないことで CPU と一時配列を削減する。
        let descriptor = FetchDescriptor<CachedDropboxItem>(
            sortBy: [SortDescriptor(\.captureDate, order: .forward)])
        guard let items = try? modelContext.fetch(descriptor) else { return [] }
        // ⚠️ contentHash は**渡さない**（nil）。表示用の長寿命配列（67k 件）に 64 桁ハッシュ文字列を
        //    常駐させると数MB級の無駄になる。変更検知は SwiftData 側の `CachedDropboxItem` と
        //    `applyDelta`（delta parser が持つ contentHash）で行うため、表示アイテムには不要。
        let result = items
            .map { DropboxFileItem(path: $0.path, name: $0.name,
                                   captureDate: $0.captureDate, latitude: $0.latitude, longitude: $0.longitude) }
        DropboxLogger.info("cachedItems() → \(result.count) items from SwiftData (accountId=\(accountId))")
        return result
    }

    /// キャッシュ済みの**パスだけ**を射影で取る（ADR-88）。
    ///
    /// ⚠️ 同期終盤の prune は「消えたファイルを見つける」ためにパスの集合しか要らないのに、
    /// 以前は `cachedItems` を呼んで 72,935 行を全列で実体化し、`DropboxFileItem` を
    /// 72,935 個作って、`.path` 以外を捨てていた。64 桁の contentHash を含む全列が
    /// 一時的にメモリへ載るため、**初回同期の山場でさらにメモリを積む**形になっていた。
    /// 射影なら 1 列だけで済む（`FaceStore` の各射影と同じ手）。
    ///
    /// - Parameter prefix: 小文字のパス接頭辞。空なら全件（マルチルートで他ルートを消さないため）。
    func cachedPaths(withPrefix prefix: String = "") -> [String] {
        let t0 = PerfTrace.nowNs()
        defer { PerfTrace.logSpan("cache.fetchPaths", ms: PerfTrace.msSince(t0)) }
        var descriptor = FetchDescriptor<CachedDropboxItem>()
        descriptor.propertiesToFetch = [\.path]
        guard let items = try? modelContext.fetch(descriptor) else { return [] }
        guard !prefix.isEmpty else { return items.map(\.path) }
        return items.map(\.path).filter { $0.lowercased().hasPrefix(prefix) }
    }

    /// キャッシュ済みアイテム数（全件ロードせず件数だけ）。同期の自己修復判定に使う。
    func cachedItemCount(accountId: String) -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<CachedDropboxItem>())) ?? 0
    }

    /// アイテム集合の変更リビジョン。`applyDelta` / `updateLocation` のたびに進む。
    ///
    /// 表示側（`DropboxPhotoStore.reflectCachedItems`）が「前回反映してから変わったか」を
    /// **68,200 行を fetch せずに**判定するための札（ADR-95）。以前は同期ポーリングのたびに
    /// 全件 fetch → 値型 68,200 個生成 → 署名計算 → 大半は「変化なし」で捨てる、を繰り返しており、
    /// 起動直後の 3 秒間だけで 2 回走って `cache.fetchItems` が 993ms / 1165ms かかっていた
    /// （実機 diagnostics-38・その直後にメインが 2.8s / 3.5s ブロック）。
    /// 変わっていないものを取り直さない（CLAUDE.md 性能原則 3 の同型）。
    private(set) var itemsRevision: Int = 0
    /// テスト用: `cachedItems`（全列の実体化）を呼んだ回数。本番では読まれない。
    private(set) var materializeCallsForTesting = 0
    /// テスト用の累計書き込み件数（本番では読まれない）。
    var insertedForTesting = 0
    var updatedForTesting = 0

    /// 変更リビジョンを読む（表示側の早期リターン用・fetch を伴わない）。
    func currentItemsRevision() -> Int { itemsRevision }

    /// 同期状態の Sendable スナップショット（`@Model` を actor 外へ漏らさない）。
    struct SyncStateInfo: Sendable, Equatable {
        let cursor: String?
        let lastSyncedAt: Date?
        /// 初回スキャンを完走した時刻（nil＝未完了）。起動時に poll へ直行してよいかの判断に使う。
        var initialSyncCompletedAt: Date?

        var isInitialSyncCompleted: Bool { initialSyncCompletedAt != nil }
    }

    func syncStateInfo(accountId: String) -> SyncStateInfo? {
        guard let state = fetchSyncState(accountId: accountId) else { return nil }
        return SyncStateInfo(cursor: state.cursor, lastSyncedAt: state.lastSyncedAt,
                             initialSyncCompletedAt: state.initialSyncCompletedAt)
    }

    /// **カーソルを捨てて、初回同期からやり直せる状態に戻す**（ADR-203）。
    ///
    /// ⚠️ Dropbox は差分カーソルを失効させることがある（`list_folder/continue` が
    /// `reset` を返す）。失効したカーソルは**二度と有効にならない**ので、投げ直しても無駄で、
    /// 捨てて一覧から作り直すしかない。キャッシュの中身（写真の行）は消さない——
    /// 初回同期は「取ってきた一覧に無いものを消す」形で収束するため。
    func resetSyncCursor(accountId: String) {
        guard let state = fetchSyncState(accountId: accountId) else { return }
        state.cursor = nil
        state.initialSyncCompletedAt = nil
        try? modelContext.save()
    }

    /// 初回スキャンの完走を記録する（完走時のみ呼ぶ）。
    func markInitialSyncCompleted(accountId: String, at date: Date = Date()) {
        let state = fetchSyncState(accountId: accountId)
            ?? {
                let created = DropboxSyncState(accountId: accountId)
                modelContext.insert(created)
                return created
            }()
        state.initialSyncCompletedAt = date
        try? modelContext.save()
    }

    /// 単発取得（get_metadata）で得た位置情報を該当アイテムへ保存する。
    /// まだ撮影日時を問い合わせていない写真のパス（最大 `limit` 件・新しい順）。
    ///
    /// ⚠️ **射影で取る**（パス 1 列だけ）。全列を実体化すると 6.8 万行ぶんの `@Model` を作る
    /// ことになる（`cachedItems` の注記と同じ理由）。
    /// ⚠️ 並びは**新しい順**。利用者が最初に見るのは一覧の末尾（最新）なので、そこから直す。
    func pathsNeedingCaptureDateProbe(limit: Int) -> [String] {
        var descriptor = FetchDescriptor<CachedDropboxItem>(
            // ⚠️ `exifProbedAt` で選ぶ。`captureDateProbedAt` だけの行（EXIF 由来か
            // アップロード時刻か区別できない時期に訊いた行）も、一度だけ訊き直す。
            predicate: #Predicate { $0.exifProbedAt == nil },
            sortBy: [SortDescriptor(\.captureDate, order: .reverse)])
        descriptor.propertiesToFetch = [\.path]
        descriptor.fetchLimit = limit
        return ((try? modelContext.fetch(descriptor)) ?? []).map(\.path)
    }

    /// 1 枚ぶんの問い合わせ結果を記録する（撮影日時・撮影地）。
    ///
    /// ⚠️ **取れなかったことも記録する**（`captureDate` は触らず `captureDateProbedAt` だけ進める）。
    /// EXIF の無い写真は何度訊いても無いので、記録しないと毎回往復することになる。
    /// - Returns: 表示に関わる値が変わったか（呼び出し側が一覧の作り直しを判断する材料）。
    @discardableResult
    func recordCaptureDateProbe(path: String, captureDate: Date?,
                                latitude: Double?, longitude: Double?,
                                probedAt: Date = Date()) -> Bool {
        guard let existing = fetchCachedItem(path: path) else { return false }
        var changed = false
        if let captureDate, existing.captureDate != captureDate {
            existing.captureDate = captureDate
            changed = true
        }
        if let latitude, existing.latitude != latitude { existing.latitude = latitude; changed = true }
        if let longitude, existing.longitude != longitude { existing.longitude = longitude; changed = true }
        existing.captureDateProbedAt = probedAt
        // EXIF の撮影日時だけを別に控える（取れなかったら nil＝「無かった」も事実として残る）。
        existing.exifCaptureDate = captureDate
        existing.exifProbedAt = probedAt
        try? modelContext.save()
        if changed { itemsRevision &+= 1 }
        return changed
    }

    /// 未問い合わせの件数（進捗表示・テスト用）。
    func captureDateProbePendingCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<CachedDropboxItem>(
            predicate: #Predicate { $0.exifProbedAt == nil }))) ?? 0
    }

    func updateLocation(path: String, latitude: Double, longitude: Double) {
        guard let existing = fetchCachedItem(path: path) else { return }
        existing.latitude = latitude
        existing.longitude = longitude
        try? modelContext.save()
        itemsRevision &+= 1
    }

    /// Applies a delta from `list_folder` / `list_folder/continue` to the cache:
    /// removes deleted entries (and their cached binaries), upserts added/changed
    /// entries (invalidating binaries when `contentHash` changed), and stores the
    /// new sync cursor.
    /// テスト用: 差分適用の書き込み件数を返す（「変わっていない行は書かない」の検証用）。
    func applyDeltaForTesting(added: [DropboxFileItem], removed: [String],
                              accountId: String) -> (inserted: Int, updated: Int) {
        let before = (insertedForTesting, updatedForTesting)
        applyDelta(accountId: accountId, added: added, removed: removed, newCursor: "c")
        return (insertedForTesting - before.0, updatedForTesting - before.1)
    }

    func applyDelta(accountId: String, added: [DropboxFileItem], removed: [String], newCursor: String) {
        DropboxLogger.info("applyDelta() — added=\(added.count), removed=\(removed.count), cursor=\(String(newCursor.prefix(DropboxInternalConstants.cursorLogPrefixLong)))")

        for path in removed {
            if let existing = fetchCachedItem(path: path) {
                modelContext.delete(existing)
            }
            invalidate(path: path)
        }

        var insertCount = 0
        var updateCount = 0
        for item in added {
            if let existing = fetchCachedItem(path: item.path) {
                // ⚠️ **変わっていない行は書かない**（実機の disk writes 警告）。
                // 以前は一致していても全項目を代入し、さらに `cachedAt = Date()` で必ず
                // 別の値にしていたため、**毎回すべての行がダーティ**になっていた。
                // 実測: 初回同期で `inserted=0 / updated=109,679`——1 件も新規が無いのに
                // 11 万行を書き直しており、OS が 12 分で 1.07GB の書き込みを検出して警告した
                // （制限の約 117 倍）。ディスク書き込みは発熱・電池・フラッシュ寿命に直結する。
                let hashChanged = existing.contentHash != item.contentHash
                // ⚠️ 一覧の日付は `client_modified`＝**アップロード時刻**（Dropbox は一覧系 API で
                // media_info を返さない・ADR-201）。1 枚ずつ問い合わせて得た撮影日時を、
                // これで上書きしてはいけない。上書きすると毎回の同期で値が行き来して
                // **全行がダーティ**になり、並びも戻る。中身が差し替わったら訊き直す。
                let keepsProbedDate = existing.captureDateProbedAt != nil && !hashChanged
                let changed = existing.name != item.name
                    || hashChanged
                    || (!keepsProbedDate && existing.captureDate != item.captureDate)
                    || (item.latitude != nil && existing.latitude != item.latitude)
                    || (item.longitude != nil && existing.longitude != item.longitude)
                guard changed else { continue }   // 触らない＝ダーティにしない
                if hashChanged {
                    invalidate(path: item.path)
                    existing.captureDateProbedAt = nil   // 中身が変わった＝撮影日時も訊き直す
                    existing.exifProbedAt = nil
                    existing.exifCaptureDate = nil
                }
                existing.name = item.name
                existing.contentHash = item.contentHash
                if !keepsProbedDate { existing.captureDate = item.captureDate }
                // 位置情報は media_info が pending のとき nil で来るため、既存値を上書きで消さない。
                if item.latitude != nil { existing.latitude = item.latitude }
                if item.longitude != nil { existing.longitude = item.longitude }
                // ⚠️ `cachedAt` は**中身が変わったときだけ**進める。無条件に更新すると
                // それ自体が「必ず変わる値」になり、上の判定を無意味にする。
                existing.cachedAt = Date()
                updateCount += 1
            } else {
                let newItem = CachedDropboxItem(
                    path: item.path,
                    name: item.name,
                    contentHash: item.contentHash,
                    captureDate: item.captureDate,
                    latitude: item.latitude,
                    longitude: item.longitude
                )
                modelContext.insert(newItem)
                insertCount += 1
            }
        }

        let state = fetchSyncState(accountId: accountId) ?? {
            let newState = DropboxSyncState(accountId: accountId)
            modelContext.insert(newState)
            return newState
        }()
        state.cursor = newCursor
        state.lastSyncedAt = Date()

        try? modelContext.save()
        // アイテム集合が実際に変わったときだけ札を進める（変化なしのポーリングでは進めない＝
        // 表示側が 68,200 件の再取得を丸ごと省ける・ADR-95）。
        if insertCount > 0 || updateCount > 0 || !removed.isEmpty { itemsRevision &+= 1 }
        insertedForTesting += insertCount
        updatedForTesting += updateCount
        DropboxLogger.verbose("applyDelta() saved — inserted=\(insertCount), updated=\(updateCount), removed=\(removed.count)")
    }

    // MARK: - Debug snapshot（デバッグ画面用：別コンテナを開かず本アクター経由で読む）

    /// デバッグ画面表示用のスナップショット（件数・使用量・直近アイテム/使用量）。
    /// 以前は DropboxCacheDebugModel が同名 "DropboxCache" ストアを**第2のコンテナ**で開いていたが、
    /// 同一ストアの二重オープンを避けるため、動作中の本アクターから読む。
    func debugSnapshot(accountId: String) -> DropboxCacheDebugSnapshot {
        let allItems = (try? modelContext.fetch(FetchDescriptor<CachedDropboxItem>())) ?? []
        let allUsage = (try? modelContext.fetch(FetchDescriptor<CacheUsageEntry>())) ?? []
        let syncState = fetchSyncState(accountId: accountId)
        let thumbKind = CacheUsageEntry.CacheKind.thumbnail.rawValue
        let fullKind = CacheUsageEntry.CacheKind.fullImage.rawValue
        let thumb = allUsage.filter { $0.kind == thumbKind }
        let full = allUsage.filter { $0.kind == fullKind }

        var itemDesc = FetchDescriptor<CachedDropboxItem>(sortBy: [SortDescriptor(\.cachedAt, order: .reverse)])
        itemDesc.fetchLimit = 50
        let recentItems = ((try? modelContext.fetch(itemDesc)) ?? []).map {
            DropboxCacheDebugSnapshot.Item(path: $0.path, name: $0.name, contentHash: $0.contentHash,
                                           captureDate: $0.captureDate, cachedAt: $0.cachedAt)
        }
        var usageDesc = FetchDescriptor<CacheUsageEntry>(sortBy: [SortDescriptor(\.lastAccessedAt, order: .reverse)])
        usageDesc.fetchLimit = 50
        let recentUsage = ((try? modelContext.fetch(usageDesc)) ?? []).map {
            DropboxCacheDebugSnapshot.Usage(key: $0.key, kind: $0.kind, byteSize: $0.byteSize,
                                            lastAccessedAt: $0.lastAccessedAt)
        }

        return DropboxCacheDebugSnapshot(
            itemCount: allItems.count,
            thumbnailCount: thumb.count, thumbnailBytes: thumb.reduce(0) { $0 + $1.byteSize },
            fullImageCount: full.count, fullImageBytes: full.reduce(0) { $0 + $1.byteSize },
            lastSyncedAt: syncState?.lastSyncedAt, syncCursor: syncState?.cursor,
            recentItems: recentItems, recentUsage: recentUsage)
    }

    // MARK: - File naming

    func store(for kind: CacheUsageEntry.CacheKind) -> DiskImageStore {
        kind == .thumbnail ? thumbnailStore : fullImageStore
    }

    // MARK: - SwiftData fetch helpers

    /// パスの束 → **EXIF の撮影日時**（取れている行だけ）。顔の撮影日に使う（ADR-218）。
    ///
    /// ⚠️ 1 枚ずつ引かない（ADR-119）。束を分けて `IN` で引く（1 回あたり 500 件）。
    func exifCaptureDates(paths: [String]) -> [String: Date] {
        var out: [String: Date] = [:]
        var start = 0
        while start < paths.count {
            let chunk = Array(paths[start..<min(start + 500, paths.count)])
            start += chunk.count
            var descriptor = FetchDescriptor<CachedDropboxItem>(
                predicate: #Predicate { chunk.contains($0.path) && $0.exifCaptureDate != nil })
            descriptor.propertiesToFetch = [\.path, \.exifCaptureDate]
            PerfTrace.count("cache.exifDates.fetch")
            for row in (try? modelContext.fetch(descriptor)) ?? [] {
                if let date = row.exifCaptureDate { out[row.path] = date }
            }
        }
        return out
    }

    /// テスト用: 「`exifProbedAt` の列ができる前に訊いた行」を作る。
    func forgetExifProbeForTesting(path: String) {
        guard let row = fetchCachedItem(path: path) else { return }
        row.exifProbedAt = nil
        row.exifCaptureDate = nil
        try? modelContext.save()
    }

    private func fetchCachedItem(path: String) -> CachedDropboxItem? {
        let predicate = #Predicate<CachedDropboxItem> { $0.path == path }
        return try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first
    }

    func fetchSyncState(accountId: String) -> DropboxSyncState? {
        let predicate = #Predicate<DropboxSyncState> { $0.accountId == accountId }
        return try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first
    }
}

/// `DropboxCacheStore` のデバッグ用スナップショット（Sendable）。`@Model` を actor 外へ漏らさず値で返す。
public struct DropboxCacheDebugSnapshot: Sendable {
    public struct Item: Sendable {
        public let path: String
        public let name: String
        public let contentHash: String?
        public let captureDate: Date?
        public let cachedAt: Date
    }
    public struct Usage: Sendable {
        public let key: String
        public let kind: String
        public let byteSize: Int
        public let lastAccessedAt: Date
    }
    public let itemCount: Int
    public let thumbnailCount: Int
    public let thumbnailBytes: Int
    public let fullImageCount: Int
    public let fullImageBytes: Int
    public let lastSyncedAt: Date?
    public let syncCursor: String?
    public let recentItems: [Item]
    public let recentUsage: [Usage]
}
#endif
