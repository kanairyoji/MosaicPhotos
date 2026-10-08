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


    /// **起動を跨ぐふるまいを試すための入口**（ADR-259）。
    ///
    /// ⚠️ なぜ要るか: 既存のテストはどれも店を 1 つ作って
    /// 「`itemIndexBuildsForTesting == 1`（＝1 回しか作っていない）」を確かめていた。
    /// だが**店 1 つ＝1 回の起動**なので、「毎起動 1 回作り直す」は
    /// **テストが望ましい性質として固定していた**——それがまさに実機の 9 秒だった
    /// （diagnostics-105・ADR-258）。起動を跨ぐ性質は、容器を共有した 2 つ目の店で見る。
    ///
    /// ⚠️ 控えの置き場も渡すこと（テストごとに別の一時ディレクトリ）。
    /// 固定パスだと並行するテストが互いの控えを上書きする。
    init(testContainer: ModelContainer, snapshotDirectory: URL) {
        modelContainer = testContainer
        modelContext = ModelContext(testContainer)
        self.snapshotDirectory = snapshotDirectory
        // ⚠️ `isEphemeral = false`＝控えを使う側の挙動を試す（在庫の目的そのもの）。
        isEphemeral = false
        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let baseURL = cachesURL.appendingPathComponent("DropboxKitTests", isDirectory: true)
        thumbnailStore = DiskImageStore(directory: baseURL.appendingPathComponent("thumbnails", isDirectory: true))
        fullImageStore = DiskImageStore(directory: baseURL.appendingPathComponent("fullimages", isDirectory: true))
        thumbnailByteLimit = DropboxInternalConstants.defaultThumbnailByteLimit
        fullImageByteLimit = DropboxInternalConstants.defaultFullImageByteLimit
        thumbnailMemory = MemoryImageCache(
            totalCostLimit: DropboxInternalConstants.thumbnailMemoryCostLimit,
            countLimit: DropboxInternalConstants.thumbnailMemoryCountLimit,
            purgeOnCritical: false,
            pressureFloor: DropboxInternalConstants.thumbnailMemoryPressureFloor)
    }

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
        // ⚠️ テスト用の容器は **`makeInMemoryModelContainer` だけ**が作る（MosaicSupport）。
        // 名前を毎回変える／生成を直列にする の 2 つが要る理由はそちらに書いてある。
        if isStoredInMemoryOnly {
            modelContainer = makeInMemoryModelContainer(for: schema)
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
        self.snapshotDirectory = Self.defaultSnapshotDirectory
        self.isEphemeral = isStoredInMemoryOnly
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
        // content_hash の表（15〜20MB）はメモリ圧迫で捨てる。作り直せるので保持する理由がない。
        // ⚠️ 解放は actor 越し＝即時ではないが、中身は辞書 1 つなので取りこぼしても害はない。
        _ = MemoryPressureMonitor.shared.register { [weak self] _ in
            Task { await self?.dropContentHashIndex() }
        }

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
    /// 軽い表の 1 行（パス・content_hash・撮影日）。表示用の全列は持たない。
    struct IndexedItem: Sendable {
        let path: String
        let hash: String?
        let captureDate: Date?
        /// 撮影日時を**訊いて確かめた**行か（`captureDateProbedAt != nil`）。
        /// ⚠️ DB 側の保持規則（ADR-201）と揃えるために要る（レビュー指摘）。持たないと
        /// 「hash は同じだがまだ訊いていない・一覧の日付だけ変わった」行で DB と食い違う。
        let probed: Bool
    }
    /// パス小文字 → 軽い行の表（ADR-222/224）。作り直さず増減で直す。
    /// ⚠️ 9.9 万件で 20〜30MB 前後。メモリ圧迫では捨てる（次の要求で作り直せる）。
    /// ⚠️ **インメモリの店（テスト）は控えを使わない**（ADR-258）。
    /// 控えは `Caches` の**1 つの固定ファイル**なので、並行して走るテストが互いのものを
    /// 上書きし得る。しかも鍵は「行数・未問い合わせ数・差し替え回数」なので、小さな
    /// fixture どうしでは**たまたま一致する**（2 行・2 件・0 回 など）——他のテストの控えを
    /// 読み込んでしまう。インメモリの店は起動を跨がないので、そもそも控える意味が無い。
    /// （`FaceStore.isEphemeral` が同じ理由で高水位を持たないのと同じ扱い）
    private let isEphemeral: Bool
    /// ディスクの控えを**この起動で一度でも読もうとしたか**（読めなくても二度は探さない＝ADR-82）。
    private var triedSnapshotLoad = false
    /// 最後にディスクへ書いた控えの鍵（同じ鍵で何度も書かない）。
    private var writtenSnapshotKey: UInt64?

    private var cachedItemIndex: [String: IndexedItem]?
    /// 表が対応している `itemsRevision`（合わなければ作り直す）。
    private var cachedItemIndexRevision = -1
    /// 表を作るときのページの大きさ（実体化した行をページごとに手放す）。
    static let indexPageSize = 5_000
    /// テスト用に小さくするための穴（既定は `indexPageSize`）。
    ///
    /// ⚠️ **継ぎ目のテストに本番の大きさを使わない**（CI が赤くなった・2026-09-29）。
    /// キーセット・ページングの継ぎ目を確かめるのに 5,037 行の fixture を 2 つ作っていたので、
    /// このスイートだけで 1 万行の挿入になり、**同じ実行で並行に走る時間依存のテストを飢餓させた**
    /// （`DropboxPhotoStoreReflectCoalesceTests` が `materialized → 0` で落ちた）。
    /// 継ぎ目の理屈はページの大きさに依らないので、テストは小さいページで跨げばよい。
    private var indexPageSizeOverrideForTesting: Int?
    private var effectiveIndexPageSize: Int { indexPageSizeOverrideForTesting ?? Self.indexPageSize }
    func setIndexPageSizeForTesting(_ size: Int) { indexPageSizeOverrideForTesting = size }
    /// テスト用: `cachedItems`（全列の実体化）を呼んだ回数。本番では読まれない。
    private(set) var materializeCallsForTesting = 0
    /// テスト用: 射影を**実際に引いた**回数（表が効いていれば増えない）。
    ///
    /// ⚠️ `PerfTrace` のカウンタで数えない（FaceCore で同じ罠を踏んだ）。あれはプロセス全体で
    /// 共有なので、並行して走る別スイートの読み出しまで混ざり、**単体では通るのに全体実行で
    /// 落ちる**。ストアごとに数える。
    private(set) var itemIndexBuildsForTesting = 0
    /// テスト用の累計書き込み件数（本番では読まれない）。
    var insertedForTesting = 0
    var updatedForTesting = 0

    /// 変更リビジョンを読む（表示側の早期リターン用・fetch を伴わない）。
    func currentItemsRevision() -> Int { itemsRevision }

    /// **写真の集合が変わった回数**（増えた／減った のみ・ADR-250）。
    ///
    /// ⚠️ `itemsRevision` と**別に持つ**理由: あちらは「一覧を作り直す必要があるか」の札で、
    /// 撮影日の問い合わせ・撮影地の解決でも進む（1 枚ずつ走るのでほぼ常に動く）。
    /// 「解析候補が変わったか」を訊きたい側がそれを使うと、**いつも『変わった』**と答えてしまう。
    /// ⚠️⚠️ これは ADR-240 と**同じ過ち**——1 つの版に 2 つ目の意味を兼ねさせた。
    /// **新しい問いには新しい札を立てる。**
    private(set) var photoSetRevision = 0

    /// 写真の集合の版を読む（fetch を伴わない）。
    func currentPhotoSetRevision() -> Int { photoSetRevision }

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
        if changed {
            itemsRevision &+= 1
            updateIndexCaptureDate(path: path, captureDate: captureDate, newRevision: itemsRevision)
        }
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
        // ⚠️ 一覧は作り直す（場所は一覧に出る）が、**表は作り直さない**（ADR-240）。
        bumpItemsRevisionKeepingIndex()
    }

    /// 一覧の版だけを進める（**表に載っている値は変えていない**とき）。
    ///
    /// ⚠️⚠️ **`itemsRevision` は 2 つの別のものを兼ねている**——一覧（`items` の作り直し）と
    /// 軽い表（`cachedItemIndex`）。表は版で覚えるので、表に無い値（緯度経度）を変えたときに
    /// 版だけ進めると、**次の要求で 10.8 万行を丸ごと作り直す**。
    /// 実機ログ diagnostics-98〜100 でこれが起きていた: 撮影地の解決は写真ごとに走るので、
    /// 1 セッションに 6 回・**1 回 35 秒**（`cache.buildItemIndex`）。しかもその間この actor は
    /// 塞がるので、`candidates.cloudRefs` も 3.7 秒 → 38 秒に膨れていた（ほぼ待ち時間）。
    /// ⚠️ 版を進める場所は 4 つあり、**表を直す／捨てる のどちらかを必ず対にする**決まりだったのに、
    /// ここだけ対になっていなかった（撮影日は `updateIndexCaptureDate`、増減は
    /// `updateContentHashIndex`、全消去は `dropContentHashIndex` と対になっている）。
    /// 新しく版を進める場所を足すときは、**この 3 つのうちどれかを必ず選ぶ**。
    private func bumpItemsRevisionKeepingIndex() {
        itemsRevision &+= 1
        // 表の中身は変わっていないので、版だけ追いつかせる（作り直させない）。
        if cachedItemIndex != nil { cachedItemIndexRevision = itemsRevision }
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
        if insertCount > 0 || updateCount > 0 || !removed.isEmpty {
            itemsRevision &+= 1
            updateContentHashIndex(added: added, removed: removed, newRevision: itemsRevision)
        }
        // ⚠️⚠️ **「写真が増減したか」は別の札で数える**（ADR-250・実機ログ diagnostics-104）。
        // `itemsRevision` は「一覧を作り直す必要があるか」の札で、**撮影日の問い合わせ**や
        // **撮影地の解決**でも進む（どちらも 1 枚ずつ走るので、ほぼ常に動いている）。
        // それを「解析候補が変わったか」の判定に流用したら、**ゲートが一度も効かなかった**
        // ——実機で `候補の列挙を見送る` が 0 件、11 回とも 8.6 万件を列挙していた。
        // 候補の集合が変わるのは**増えたか減ったか**だけなので、専用の札を持つ。
        // ⚠️ `updateCount`（中身の差し替え）では進めない——同じ写真のままなので候補は変わらない。
        if insertCount > 0 || !removed.isEmpty { photoSetRevision &+= 1 }
        // ⚠️ **件数では捕まえられない変化**（同じパスのまま hash が変わる）だけを数える
        // ＝軽い表のディスク控えの鍵に使う（ADR-258）。増減は行数で分かるので含めない。
        if updateCount > 0 { bumpHashUpdateCount() }
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

    /// 全クラウド写真の **パス小文字 → content_hash**（射影・ADR-222）。
    ///
    /// ⚠️ **`cachedItems` で代用しない**。表示用の `DropboxFileItem` は `contentHash` を
    /// **わざと持たない**（67k 件の長寿命配列に 64 桁の文字列を常駐させないため）。
    /// 実際それに気づかず `dropboxStore.items` から hash を拾う実装にしてしまい、
    /// 解析の公開が毎回「クラウド写真が 0 件」で何もしなかった（実機ログ diagnostics-84）。
    /// しかも `items` は**画面を開いたときだけ**作られるので、背景の窓では空のことがある。
    /// 用途は「今ある写真ぜんぶの hash」なので、2 列だけの射影で取る。
    func cachedContentHashes() -> [String: String] {
        itemIndex().compactMapValues(\.hash)
    }

    /// 解析候補に要る **パスと撮影日だけ**（ADR-224）。
    func cachedPhotoRefs() -> [CloudPhotoRef] {
        // ⚠️ **並びを決めておく**（レビュー指摘）。辞書の `values` はプロセスごとに順が変わるので、
        // 撮影日が同値・不明な写真の解析順が起動のたびに変わっていた（以前は DB の昇順で決定的）。
        itemIndex().values
            .map { CloudPhotoRef(path: $0.path, captureDate: $0.captureDate) }
            .sorted { ($0.captureDate ?? .distantPast, $0.path) > ($1.captureDate ?? .distantPast, $1.path) }
    }

    // MARK: - 軽い表のディスク控え（ADR-258）

    /// 控えの置き場。⚠️ `Caches`（OS が消してよい＝作り直せる表にふさわしい）。
    ///
    /// ⚠️ **テストでは必ず差し替える**（`init(testContainer:snapshotDirectory:)`）。
    /// 本番は 1 プロセス 1 ファイルでよいが、テストは並行に走るので固定パスだと
    /// 互いの控えを上書きし合う（しかも小さな fixture では鍵がたまたま一致する）。
    private let snapshotDirectory: URL

    private var snapshotURL: URL {
        try? FileManager.default.createDirectory(at: snapshotDirectory,
                                                 withIntermediateDirectories: true)
        return snapshotDirectory.appendingPathComponent("item-index.bin")
    }

    static var defaultSnapshotDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DropboxKit", isDirectory: true)
    }

    /// 中身差し替えの回数を持つ**予約行**（ADR-258）。
    ///
    /// ⚠️ 本物のアカウント ID と衝突しない名前にする（`accountId` は `.unique`）。
    /// ⚠️⚠️ 最初は `UserDefaults` に置いたが、**プロセスで 1 つしかない**ので別のストアの
    /// 更新がこちらの鍵を動かした（並行テストが落ちて気づいた）。
    /// 鍵の材料は**その容器から導けるもの**でなければならない。
    private static let indexVersionRowKey = "__mosaic.itemIndexContentVersion__"

    /// 同じパスのまま中身が差し替わった回数（件数では捕まえられない唯一の変化）。
    /// ⚠️ `#Predicate` は `Self.` のメンバをたためない（マクロ展開で型が合わない）。
    /// 必ず**ローカルの `let` に写してから**使う。
    private func indexVersionRow() -> DropboxSyncState? {
        let key = Self.indexVersionRowKey
        var d = FetchDescriptor<DropboxSyncState>(predicate: #Predicate { $0.accountId == key })
        d.fetchLimit = 1
        return (try? modelContext.fetch(d))?.first
    }

    private func hashUpdateCount() -> Int {
        indexVersionRow()?.indexContentVersion ?? 0
    }

    private func bumpHashUpdateCount() {
        if let row = indexVersionRow() {
            row.indexContentVersion = (row.indexContentVersion ?? 0) + 1
        } else {
            let row = DropboxSyncState(accountId: Self.indexVersionRowKey)
            row.indexContentVersion = 1
            modelContext.insert(row)
        }
        try? modelContext.save()
    }

    /// **控えを使ってよいかの鍵**（ADR-258）。
    ///
    /// ⚠️⚠️ `itemsRevision` は使えない——**メモリだけの値で起動ごとに 0 に戻る**ので、
    /// 鍵にすると前の起動の控えを「同じ版」と誤って受け入れる（ADR-250 の流用と同じ罠）。
    /// カーソルも使えない——**変化の無いポーリングでも進む**（applyDelta が毎回書く）ので、
    /// 鍵が常に変わって控えが一度も当たらない。
    ///
    /// だから **DB から導ける 2 つの数 ＋ 中身差し替えの回数**にする:
    /// 1. 全行数（増減を捕まえる。`fetchCount`＝安い）
    /// 2. まだ EXIF を訊いていない行数（撮影日の問い合わせを捕まえる。probe は必ずこれを減らす）
    /// 3. 中身が差し替わった回数（件数が変わらない変化を捕まえる）
    ///
    /// 3 つとも**同じ容器（DB）から導ける**こと。⚠️ 最初は 3 を `UserDefaults` に置いたが、
    /// あれはプロセスで 1 つしかないので**別のストアの更新がこちらの鍵を動かす**
    /// （並行テストが落ちて気づいた）。容器が作り直されたら鍵も一緒に消えるのが正しい。
    ///
    /// ⚠️ 残る穴（書いておく・ADR-250 と同じ作法）: 1・2・3 が全部一致して中身だけ違う状況
    /// ——「同数の入れ替えが起き、しかも hash は変わらない」——は理屈上あり得る。
    /// その場合に当たる害は「控えが 1 周期ぶん古い」だけで、次の変化で直る。
    private func snapshotKey() -> UInt64 {
        let all = (try? modelContext.fetchCount(FetchDescriptor<CachedDropboxItem>())) ?? -1
        let unprobed = (try? modelContext.fetchCount(FetchDescriptor<CachedDropboxItem>(
            predicate: #Predicate { $0.exifProbedAt == nil }))) ?? -1
        let updates = hashUpdateCount()
        // FNV-1a（決まった値になればよいだけ・暗号用途ではない）。
        var h: UInt64 = 0xcbf29ce484222325
        for part in [all, unprobed, updates] {
            withUnsafeBytes(of: Int64(part).littleEndian) { bytes in
                for byte in bytes { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
            }
        }
        return h
    }

    /// 控えから表を復元する。鍵が合わなければ nil（＝作り直す）。
    private func loadIndexSnapshot(key: UInt64) -> [String: IndexedItem]? {
        guard let data = try? Data(contentsOf: snapshotURL),
              let payload = DropboxItemIndexSnapshot.decode(data),
              payload.contentVersion == key else { return nil }
        var out: [String: IndexedItem] = [:]
        out.reserveCapacity(payload.rows.count)
        for row in payload.rows {
            out[row.path.lowercased()] = IndexedItem(path: row.path, hash: row.hash,
                                                     captureDate: row.captureDate,
                                                     probed: row.probed)
        }
        return out
    }

    private func writeIndexSnapshot(_ index: [String: IndexedItem], key: UInt64) {
        guard !isEphemeral, writtenSnapshotKey != key else { return }
        let rows = index.values.map {
            DropboxItemIndexSnapshot.Row(path: $0.path, hash: $0.hash,
                                         captureDate: $0.captureDate, probed: $0.probed)
        }
        let data = DropboxItemIndexSnapshot.encode(
            .init(contentVersion: key, rows: rows))
        // ⚠️ 空＝桁に収まらない行があって控えを作らなかった（`encode` のコメント参照）。
        // 0 バイトのファイルを置くと、次の起動が「控えはある」と思って読んで失敗する。
        guard !data.isEmpty else {
            DropboxLogger.info("itemIndex: 控えを作れなかった（桁に収まらない行がある）")
            return
        }
        // ⚠️ `.atomic`（途中で死んでも半端なファイルを残さない＝次の起動が壊れた控えを読む）。
        do {
            try data.write(to: snapshotURL, options: .atomic)
            writtenSnapshotKey = key
            DropboxLogger.info("itemIndex: 控えを書いた（\(rows.count) 行・\(data.count / 1024)KB）")
        } catch {
            DropboxLogger.error("itemIndex: 控えを書けなかった — \(error.localizedDescription)")
        }
    }

    /// **いまの表で控えを書き直す**（ADR-260）。
    ///
    /// ⚠️ なぜ要るか: 控えは「表を作り直した回」にしか書いていなかった。ところが
    /// 撮影日の問い合わせ（ADR-257・1 枠 500 枚）は**表を作り直さず中身だけ直す**ので、
    /// 鍵（未問い合わせ数を含む）は変わるのに控えは古いまま——
    /// **次の起動で鍵が合わず、必ず作り直す**。つまり ADR-258 は撮影日が埋まり切るまで
    /// （実機で約 2 か月）ほとんど効かない。1 枠の終わりに 1 回だけ書き直す。
    ///
    /// ⚠️ 表がそろっていないときは**何もしない**（ここで作り始めると 9 秒を払う）。
    /// ⚠️ 呼ぶのは**枠の中で 1 回**（前面の 3 秒ごとの trickle から呼ぶと 10MB を書き続ける）。
    func refreshIndexSnapshotIfReady() {
        guard !isEphemeral, let index = cachedItemIndex,
              cachedItemIndexRevision == itemsRevision else { return }
        writeIndexSnapshot(index, key: snapshotKey())
    }

    /// テスト用: 控えの鍵（材料の約束を縛るため・ADR-251/258）。
    func snapshotKeyForTesting() -> UInt64 { snapshotKey() }

    /// テスト用: 控えを消す。
    func removeIndexSnapshotForTesting() {
        try? FileManager.default.removeItem(at: snapshotURL)
        writtenSnapshotKey = nil
        triedSnapshotLoad = false
    }

    /// 軽い表（パス小文字 → パス・hash・撮影日）を返す。無ければ 1 回だけ作る。
    ///
    /// ⚠️ **SwiftData の `propertiesToFetch` は列を絞らない**（実機ログ diagnostics-94）。
    /// 「2 列だけの射影」のつもりで書いた `cachedPhotoRefs` は、実測 **16.3 秒・
    /// フットプリント 831MB**——`cachedItems`（全列）と変わらなかった。あの指定は**ヒント**で、
    /// `PersistentModel` は結局まるごと実体化される。
    /// だから (1) **一度だけ**作って以後は増減で直し、(2) 作るときは**使い捨ての `ModelContext` で
    /// ページ分け**して、実体化した行をページごとに手放す（ADR-119 の常套手段）。
    private func itemIndex() -> [String: IndexedItem] {
        if let index = cachedItemIndex, cachedItemIndexRevision == itemsRevision { return index }
        // ⚠️ **起動のたびに 10.8 万行を歩き直さない**（ADR-258・実機ログ diagnostics-105 で
        // `cache.buildItemIndex` が 9.0 秒 × 毎起動。その間この actor は塞がる）。
        // 控えは Caches に置き、鍵（DB 由来の 2 つの数＋中身差し替えの回数）が合えばそのまま使う。
        let key = snapshotKey()
        if !isEphemeral, !triedSnapshotLoad {
            triedSnapshotLoad = true
            let t = PerfTrace.nowNs()
            if let restored = loadIndexSnapshot(key: key) {
                PerfTrace.logSpan("cache.loadItemIndexSnapshot", ms: PerfTrace.msSince(t))
                Diagnostics.mark("itemIndex: 控えから復元（\(restored.count) 行・作り直しを省いた）")
                cachedItemIndex = restored
                cachedItemIndexRevision = itemsRevision
                writtenSnapshotKey = key
                return restored
            }
            Diagnostics.mark("itemIndex: 控えが使えない（作り直す）")
        }
        let t0 = PerfTrace.nowNs()
        // ⚠️ 表の作り直しは 9.9 万行を触る（実測 16 秒）。この actor は**その間ずっと塞がる**ので、
        // 重い一括ロードとして申告する（ADR-122・`cachedItems` の呼び出し側と同じ扱い）。
        HeavyLoad.begin("cache.itemIndex")
        defer {
            HeavyLoad.end("cache.itemIndex")
            PerfTrace.logSpan("cache.buildItemIndex", ms: PerfTrace.msSince(t0))
        }
        PerfTrace.count("cache.itemIndex.build")
        itemIndexBuildsForTesting += 1
        var out: [String: IndexedItem] = [:]
        out.reserveCapacity(4096)
        // ⚠️⚠️ **オフセットで送らない**（ADR-143・実機ログ diagnostics-98〜100 で踏んだ）。
        // ここだけ `fetchOffset` のままだった——`AutoAlbumStore` は ADR-143 で直っているのに。
        // 2 つの実害がある:
        //  1. **O(n²)**。SQLite は毎ページで offset 行を読み捨てるので、10.8 万行では
        //     実測 **16 → 24 → 32 → 35 秒**（ライブラリが育つほど悪化）。この actor は
        //     その間ずっと塞がる。
        //  2. ⚠️ **行が黙って飛ぶ**。この表を作っている 35 秒の間にも `applyDelta` は
        //     行を挿入する（longpoll は数秒おき）。カーソルより前に 1 行入るだけで以降の
        //     全ページが 1 つずれ、**入っていたはずの写真が表から落ちる**。
        //     しかも表は版で覚えるので、**欠落は次に版が変わるまで直らない**
        //     ——すぐ下のコメントが「欠けた表を完成品として保存してしまう」と言っているのと
        //     同じ事故が、失敗していなくても起きていた。
        // `path` は `@Attribute(.unique)`（＝索引つき）なので、キーセット・ページングが効く。
        // ⚠️ 並びは `.lexical`（ADR-178）。`>` と同じ順序でないと継ぎ目で行が飛ぶ。
        var cursor: String?
        while true {
            // ⚠️ ページごとに**別の `ModelContext`** を使う。長生きのコンテキストは実体化した行を
            // 登録し続けるので、ページ分けしてもメモリは減らない。
            let context = ModelContext(modelContainer)
            var descriptor: FetchDescriptor<CachedDropboxItem>
            if let cursor {
                descriptor = FetchDescriptor<CachedDropboxItem>(
                    predicate: #Predicate { $0.path > cursor },
                    sortBy: [SortDescriptor(\.path, comparator: .lexical)])
            } else {
                descriptor = FetchDescriptor<CachedDropboxItem>(
                    sortBy: [SortDescriptor(\.path, comparator: .lexical)])
            }
            descriptor.fetchLimit = effectiveIndexPageSize
            // ⚠️ **失敗を「終わり」と読み違えない**（レビュー指摘）。`try?` で潰すと空ページに
            // 見えるので、そこで打ち切った**欠けた表**を「完成品」として保存してしまう。
            // 以後は版が変わるまで引き直さないので、欠落は永久に直らない
            // （公開が一部の写真だけになる・候補から恒久的に漏れる）。
            guard let page = try? context.fetch(descriptor) else {
                DropboxLogger.error("buildItemIndex: fetch failed after \(out.count) rows — 表は作らない")
                return out   // 保存しない＝次の要求でやり直す
            }
            for row in page {
                out[row.path.lowercased()] = IndexedItem(path: row.path, hash: row.contentHash,
                                                         captureDate: row.captureDate,
                                                         probed: row.captureDateProbedAt != nil)
            }
            if page.count < effectiveIndexPageSize { break }
            cursor = page.last?.path
        }
        cachedItemIndex = out
        cachedItemIndexRevision = itemsRevision
        // ⚠️ **完成した表だけを控える**。上の `return out`（fetch 失敗）は控えない
        //    ——欠けた表を控えると、次の起動が欠けたまま走る。
        writeIndexSnapshot(out, key: key)
        return out
    }

    /// 増減のぶんだけ表を直す（`applyDelta` の中から呼ぶ）。表がまだ無ければ何もしない
    /// ——次に要求されたときに 1 回だけ作る。
    private func updateContentHashIndex(added: [DropboxFileItem], removed: [String],
                                        newRevision: Int) {
        guard cachedItemIndex != nil else { return }
        for path in removed { cachedItemIndex?[path.lowercased()] = nil }
        for item in added {
            let key = item.path.lowercased()
            // ⚠️ **訊いて得た撮影日時を、一覧の日付で潰さない**（ADR-201 と同じ決まり）。
            // 一覧（delta）の日付は `client_modified`＝アップロード時刻。中身が同じなら、
            // 表に入っている日付（EXIF 由来のことがある）をそのまま残す。
            let existing = cachedItemIndex?[key]
            let hashChanged = existing?.hash != item.contentHash
            // DB 側と同じ規則（`applyDelta` の `keepsProbedDate`）: **訊いて確かめた日付**は
            // 一覧の日付（＝アップロード時刻）で上書きしない。中身が変わったら訊き直す＝印も落とす。
            let keepsDate = (existing?.probed ?? false) && !hashChanged
            cachedItemIndex?[key] = IndexedItem(
                path: item.path, hash: item.contentHash,
                captureDate: keepsDate ? existing?.captureDate : item.captureDate,
                probed: keepsDate)
        }
        cachedItemIndexRevision = newRevision
    }

    /// 訊いて得た撮影日時を表へ反映する（`recordCaptureDateProbe` から呼ぶ）。
    private func updateIndexCaptureDate(path: String, captureDate: Date?, newRevision: Int) {
        guard let existing = cachedItemIndex?[path.lowercased()] else { return }
        cachedItemIndex?[path.lowercased()] = IndexedItem(
            path: existing.path, hash: existing.hash,
            captureDate: captureDate ?? existing.captureDate, probed: true)
        cachedItemIndexRevision = newRevision
    }

    /// アイテム集合が変わったことを知らせる（表示側の再反映と表の作り直しの合図）。
    func bumpItemsRevision() { itemsRevision &+= 1 }

    /// 表を捨てる（メモリ圧迫・アカウント切替・リセット）。次の要求で作り直す。
    func dropContentHashIndex() {
        cachedItemIndex = nil
        cachedItemIndexRevision = -1
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
