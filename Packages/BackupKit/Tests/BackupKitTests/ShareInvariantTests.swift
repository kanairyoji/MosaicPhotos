import Foundation
import Testing
@testable import BackupKit
import DropboxCore
import DropboxTestSupport
import MosaicSupport

/// **クラウド共有の不変条件**（ランダムな操作列に対して成り立つべきこと）。
///
/// ## なぜ要るか
/// 既存のテストは 2 層ある——`SharePureLogicTests` が「1 回の計画が正しいか」、
/// `ShareScenarioTests` が「台本どおりの筋書きで収束するか」。どちらも**筋書きを人が書く**ので、
/// 人が思いつかなかった組み合わせは通らない。
/// ところが実障害（diagnostics-52 / 55 / 64〜66・ADR-172）は**すべて組み合わせと順序**で起きた
/// ——タイムアウト × リトライ × 自己同期、コピー失敗 × 掃除、移行 × 衝突、削除 × 遅れて完走したジョブ。
///
/// そこで「**どんな操作列の後でも成り立つべきこと**」を宣言し、操作列の方を乱数で作る。
/// ⚠️ 種は固定する（落ちたら同じ列を再生できないと直せない）。
///
/// ## 不変条件
/// 1. **収束**: 健全なサーバーで反映を繰り返すと、実在 ＝ 望ましい集合になり、
///    さらに 1 回反映しても**書き込みが 1 件も起きない**。
/// 2. **消してはいけないものを消さない**: メンバーである写真の中身が、削除で失われない。
/// 3. **重複が無い**: 同じ写真（content_hash）が、それを持つメンバーの数より多く置かれない。
/// 4. **孤児が無い**: どのセットのメンバーでもない写真・フォルダが残らない。
/// 5. **受信側が復元できる**: 全メンバーに解析データが届く。
/// 6. **実在を知らずに書かない**（ADR-277）: 操作列の**途中も含めて**、既に在る宛先へ
///    コピーを投げない（`FakeDropboxServer.conflictedCopyEntries == 0`）。
/// 7. **最後の 1 枚を消さない**（ADR-278）: 操作列の途中も含めて、中身がアカウントのどこにも
///    残らない削除をしない（`FakeDropboxServer.deletedLastCopies == 0`）。
///    操作に `backupVanishes`（Backup の実物が消え、照合が記録を消す）を入れたのはこのため
///    ——それまでの操作では、共有コピーが最後の 1 枚になる状態が作られなかった。
///    ⚠️ 記録が消えた写真は、2 は「記録のあるメンバー」だけに求め、4 は「どのメンバーでもない」で見る
///    （記録が消えたメンバーのコピーは**残すのが正しい**）。
///
/// ## ⚠️ 1〜5 だけでは見えなかったもの（実機ログ diagnostics-108・ADR-277）
/// 一覧が取れなかった回に「共有ルートはまだ無い → 作れた → **空**」と読み、置き済みの写真を
/// 全部コピーし直しに行っていた。操作列には `listFailure` が**最初から入っていた**のに通っていた。
/// 理由は 2 つ:
/// - 1〜5 は**終わりの状態**だけを見る（`settle` で健全なサーバーに戻してから）。
///   この誤りは衝突で全部失敗し、次の回で自然に正しい数に戻るので、終わりの状態には残らない。
/// - 誤った回の害は「無駄な書き込み」と「表示の数が一時的に 0」で、**機能の外側**（ADR-259）。
/// だから 6 は**途中の回の振る舞い**を見る。⚠️ 自然に直る誤りは、終わりの状態の検査では原理的に捕まらない。
///
/// ## この網が捕まえたもの（2026-09-21）
/// **差分方式へ移る前**（記録が真実）の実装では、8 種のうち 3 種が壊れた。
/// どれも既存のテストでは出ていなかった。
/// - 種 2: **孤児**——どのセットのメンバーでもない写真が共有フォルダに残る（家族には見えたまま）。
/// - 種 3: **メンバーの写真が無い**——記録は「コピー済み」なのに実体が無い（家族に見えない）。
/// - 種 4: **収束しない**——落ち着いたはずの反映が毎回 1 件書き込む。
///
/// 3 つとも「記録が真実」という設計に由来する。記録と実在が食い違ったとき、食い違いの
/// 種類ごとに直し方（採用・自己修復・墓標・掃除）を足してきたが、組み合わせが増えるほど漏れが出る。
/// **差分方式（ADR-209）へ移したら 3 件とも消えた。**
///
/// 移行のさなかにも 1 件捕まえた——「メンバーが 0 のセットは何もしない」と早期に戻ると、
/// フォルダに残った自分のコピーが誰にも掃除されない孤児になる。
/// 差分では「望ましい集合が空」も立派な答えで、早期 return がそれを潰していた。
///
/// ## ⚠️ この網が ADR-278 の 6 回のレビューで出た欠陥を 1 つも捕まえなかった理由（追補 7）
/// 欠陥はどれも、**この世界に無いもの**の上で起きていた。網の目ではなく、世界が狭かった。
/// - **反映の途中で誰も何もしない**: 操作は反映と反映の**間**にしか入らなかった。実際は
///   反映（数分）の途中で利用者がセットを作り直し、写真を入れ直し、家族が写真を置く。
///   → `midSync`（偽サーバーの往復ごとの口から、反映の途中に操作を割り込ませる）と `familyDrop`。
/// - **端末が 1 台**: 他の端末の共有コピーが無いので、それを「他にある」と数える誤りが作れなかった。
///   しかも 7 の数え方（アカウントのどこかに残れば良し）では、作れても数えられなかった。
///   → 世界に他の端末の共有コピーを置き、7 を「消えてよい場所の外に残るか」で数える（7'）。
/// - **写真の中身がすべて別**: `hash = "h\(index)"` で、中身もファイル名も同じ写真が無かった。
///   重複写真の記録の持ち主が反映ごとに入れ替わる欠陥は、1（収束）なら捕まえられた——材料が無かった。
///   → 中身もファイル名も同じ写真を 2 組入れる。
/// - **一覧が 1 ページに収まる・中身を訊く口が失敗しない・写真が編集されない**:
///   → ページを 3 件にし、`listContinueFailure` / `metadataFailure` / `photoEdited` を足す。
/// - **途中で消したメンバーは、次の反映がコピーし直す**: 終わりの状態はいつも正しく、
///   1〜7 は「最後の 1 枚」でない限り見えない（ADR-277 の「自然に直る誤り」と同じ形）。
///   → 8: **消した瞬間に**「そのフォルダはその中身を失ってよかったか」を偽サーバーが数える。
///
/// 8. **いまのメンバーを消さない**（途中の回も含めて）: 消す・移す時点でセットのメンバーである
///    中身を、そのセットのフォルダから失わせない（`FakeDropboxServer.removedProtectedCopies == 0`）。
///    守る表はテストが利用者の操作のたびに書き直す。
/// 9. **落ち着いたら 2 回続けて何も書かない**（1 を 2 回）: 持ち主が交互に入れ替わる形は、
///    1 回だけ見ると偶然 0 になる回を拾い得る。
/// 11. **バックアップも落ち着く**: 落ち着いた後のバックアップは 1 枚も上げ直さない（`checkBackupSettles`）。
/// 10. **網が働いている**: 仕掛けた割り込みは必ず発火し（発火しない割り込みは何も試していない）、
///    操作の種類は種の全体でどれも選ばれる（`operationsAreAllExercised`）。
@Suite("クラウド共有の不変条件（ランダム操作列）", .serialized)
@MainActor
struct ShareInvariantTests {

    private static let backupRoot = "/MosaicPhotos"
    private static var shareRoot: String {
        BackupLayout.shareRoot(root: backupRoot, deviceFolder: BackupDeviceIdentity.currentFolderName())
    }

    // MARK: - 乱数（種を固定して再現できるようにする）

    /// 決定的な擬似乱数（SplitMix64）。⚠️ `Int.random` は種を固定できないので使わない。
    private struct Seeded {
        private var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: Range<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }
        mutating func pick<T>(_ items: [T]) -> T? {
            items.isEmpty ? nil : items[int(0..<items.count)]
        }
        mutating func chance(_ percent: Int) -> Bool { int(0..<100) < percent }
    }

    // MARK: - 世界

    /// 1 回のシナリオぶんの環境。
    private struct World {
        let engine: ShareSyncEngine
        let store: BackupStore
        let server: FakeDropboxServer
        let defaults: UserDefaults
        /// 解析データの出どころ。⚠️ 強い参照を**ここで**持つ——`engine.analysisSource` は `weak` なので、
        /// 代入しただけでは即座に解放され、解析データが一度も作られない（追補 7 まで 5 は空振りしていた）。
        let analysis: StubAnalysisSource
        /// 端末にある写真（refKey → content_hash）。バックアップ済みのものだけ共有できる。
        var photos: [String: String]
        /// refKey → Backup の実物のパス。
        var backupPaths: [String: String] = [:]
        /// Backup の実物が消えた写真（`backupVanishes`）。
        var vanished: Set<String> = []
        /// 家族が置いた写真の数（名前と中身を一意にするため）。
        var familyDrops = 0
        /// 編集の回数（新しい中身を一意にするため）。
        var edits = 0
        /// アプリの同期一覧（Dropbox 全体のパス → 中身）。**古いことがある**（`cloudIndexRefresh` で取り直す）。
        let cloudIndex: CloudIndex
        /// 消したセットのフォルダ（家族が、消える前のフォルダに写真を置くことがある）。
        var retiredFolders: [String] = []
    }

    /// アプリの同期一覧の写し。⚠️ 本物の一覧は Dropbox 全体（他の端末の `Share` も含む）で、
    /// しかも遅れる——消えたファイルが載ったまま、置かれたファイルが載らないまま、がある。
    /// 追補 7 より前の世界はこれを渡しておらず、「一覧の中の共有コピーを証拠に数える」誤りが作れなかった。
    @MainActor final class CloudIndex {
        var snapshot: [String: String] = [:]
        func refresh(from server: FakeDropboxServer) async {
            var out: [String: String] = [:]
            for path in await server.filePaths() { out[path] = await server.contentHash(at: path) ?? "" }
            snapshot = out
        }
    }

    /// 他の端末（同じ Dropbox）の端末フォルダ名。そこの `Share` は持ち主がいつ消してもよい。
    private static let otherDevice = "iPad-ZZ99ZZ"

    /// **消えてよい場所**（テストの規則・本番の規則を借りない）: どの端末の `Share` も、旧 `/MosaicShare` も。
    /// ⚠️ `ShareRemoved` は入れない——アプリが自動では消さない退避先なので、そこに在れば写真は残っている。
    private static let isDisposable: @Sendable (String) -> Bool = { path in
        let parts = path.lowercased().split(separator: "/")
        return parts.contains("share") || parts.first == "mosaicshare"
    }

    private func makeWorld(photoCount: Int, seed: UInt64) async -> World {
        let defaults = TestDefaults.scratch("share-invariant-\(seed)")
        defaults.set(true, forKey: ShareSettingsKeys.provideEnabled)
        defaults.set(Self.backupRoot, forKey: BackupSettingsKeys.dropboxFolder)

        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        let server = FakeDropboxServer()
        // ⚠️ 一覧を小さいページに分ける（続きの失敗と、ページの継ぎ目を通すため）。
        await server.setPageSize(3)
        await server.setDisposableLocation(Self.isDisposable)
        // 解析データ（`.mosaic-share/`）は端末の解析から作り直せる。古いシャードの掃除は正しい。
        await server.setRebuildableLocation { $0.contains("/\(ShareAnalysisData.subfolderName)/") }
        var photos: [String: String] = [:]
        var backupPaths: [String: String] = [:]
        for index in 0..<(photoCount + Self.duplicateCount) {
            // ⚠️ **同名の別写真を混ぜる**。宛先名の衝突は実障害の温床だった（diagnostics-52）。
            // ⚠️ 末尾の `duplicateCount` 枚は、先頭の写真と**中身もファイル名も同じ**（重複写真）。
            //    記録の持ち主が反映ごとに入れ替わる欠陥（ADR-278 追補 2）の材料。
            //    本物と同じく、重複写真は **Backup の同じファイル**に落ちる（同じ名前・同じ中身なので
            //    2 枚目のアップロードは 409 → 中身が同じ → 済み）。記録は 1 件で、持ち主が 2 人。
            let twin = index >= photoCount ? index - photoCount : index
            let name = "IMG_\(twin % max(1, photoCount / 2)).jpg"
            let path = "/mosaicphotos/backup/\(twin)/\(name)"
            let hash = "h\(twin)"
            if twin == index { await server.seed(path, hash: hash) }
            await store.upsertRecord(dropboxPath: path, localIdentifier: "p\(index)",
                                     filename: name, creationDate: nil, contentHash: hash,
                                     people: [], albums: [], isFavorite: false)
            photos["L-p\(index)"] = hash
            backupPaths["L-p\(index)"] = path
        }
        let engine = ShareSyncEngine(tokenProvider: FakeTokenProvider(),
                                     storeProvider: { store }, httpClient: server,
                                     defaults: defaults)
        engine.pollIntervalNs = 1_000_000
        engine.maxPollAttempts = 3
        let analysis = StubAnalysisSource(photos: photos)
        engine.analysisSource = analysis
        // 他の端末の共有コピー（同じ中身）。持ち主の端末はいつでも消せるので、
        // これを「他にある」と数えて消すと、2 台がお互いを当てにして両方消す（ADR-278 追補 1）。
        let otherShare = BackupLayout.shareRoot(root: Self.backupRoot, deviceFolder: Self.otherDevice)
        // ⚠️ 印の付いた名前と、印の無い古い名前の両方を置く——印だけで見分ける実装を通さないため。
        if photoCount > 3 {
            await server.seed("\(otherShare)/Trip/IMG_2--\(String(repeating: "ab", count: 32)).jpg", hash: "h2")
            await server.seed("\(otherShare)/Trip/IMG_3 (1).jpg", hash: "h3")
        }
        let cloudIndex = CloudIndex()
        await cloudIndex.refresh(from: server)
        engine.cloudSourceHashProvider = { [cloudIndex] in cloudIndex.snapshot }
        return World(engine: engine, store: store, server: server, defaults: defaults,
                     analysis: analysis, photos: photos, backupPaths: backupPaths,
                     cloudIndex: cloudIndex)
    }

    /// 中身もファイル名も同じ写真の組の数。
    private static let duplicateCount = 2

    /// 解析データの出どころ（全メンバーにタグを 1 つ返すだけ）。
    @MainActor private final class StubAnalysisSource: ShareAnalysisSource {
        var photos: [String: String]
        init(photos: [String: String]) { self.photos = photos }
        func analysisEntries(forRefKeys refKeys: [String]) async
            -> (versions: ShareAnalysisData.Versions, entries: [String: ShareAnalysisData.Entry]) {
            var entries: [String: ShareAnalysisData.Entry] = [:]
            for key in refKeys { entries[key] = ShareAnalysisData.Entry(tags: ["x"]) }
            return (ShareAnalysisData.Versions(tag: 1), entries)
        }
    }

    // MARK: - 観測

    /// 共有ルート配下の写真（小文字パス → content_hash）。解析データは除く。
    private func sharedPhotos(_ world: World) async -> [String: String] {
        let root = Self.shareRoot.lowercased() + "/"
        var out: [String: String] = [:]
        for path in await world.server.filePaths() where path.hasPrefix(root) {
            guard !path.contains("/\(ShareAnalysisData.subfolderName)/") else { continue }
            out[path] = await world.server.contentHash(at: path) ?? ""
        }
        return out
    }

    /// いまセットに入っていて、**記録がある**写真（共有できるはずのもの）の中身。
    private func resolvableMemberHashes(_ world: World) async -> Set<String> {
        var out = Set<String>()
        for set in await world.store.allShareSets() {
            let items = await world.store.shareItems(setID: set.id)
            let ids = items.map { String($0.refKey.dropFirst(2)) }
            let refs = await world.store.backupRefs(forLocalIdentifiers: ids)
            for item in items where refs[String(item.refKey.dropFirst(2))] != nil {
                if let hash = world.photos[item.refKey] { out.insert(hash) }
            }
        }
        return out
    }

    /// いまセットに入っている写真（refKey → hash）をセットごとに。
    private func members(_ world: World) async -> [UUID: [String: String]] {
        var out: [UUID: [String: String]] = [:]
        for set in await world.store.allShareSets() {
            var m: [String: String] = [:]
            for item in await world.store.shareItems(setID: set.id) {
                m[item.refKey] = world.photos[item.refKey] ?? ""
            }
            out[set.id] = m
        }
        return out
    }

    /// 偽サーバーに「いまのメンバー」を教える（8 の表）。利用者の操作のたびに呼ぶ。
    /// - 記録のあるメンバー: **中身**を守る（どの名前のコピーでも、そのフォルダに 1 つは残ること）。
    /// - 記録が消えたメンバー: **そのメンバーが置いたコピー**を守る（残すのが正しい・7 の注記）。
    ///   ⚠️ 中身で守らない——アプリは記録を失った写真の中身を知らない。重複写真の片割れのコピー
    ///   （印は別の写真）は、アプリから見れば別の写真のコピーで、退避（中身は残る）が正しい。
    ///   中身で守っていた版はこれを「メンバーを消した」と数えた（オラクルの方が強すぎた）。
    private func refreshProtected(_ world: World) async {
        var table: [String: Set<String>] = [:]
        var paths = Set<String>()
        let root = ShareSettingsKeys.currentShareRoot(world.defaults)
        for set in await world.store.allShareSets() {
            guard let folder = SharePlanning.setFolderPath(shareRoot: root, folderName: set.folderName,
                                                           deviceFolder: nil)?.lowercased() else { continue }
            let items = await world.store.shareItems(setID: set.id)
            let refs = await world.store.backupRefs(forLocalIdentifiers: items.map { String($0.refKey.dropFirst(2)) })
            for item in items {
                guard let hash = world.photos[item.refKey] else { continue }
                if refs[String(item.refKey.dropFirst(2))] != nil {
                    table[folder, default: []].insert(hash)
                } else if let source = world.backupPaths[item.refKey] {
                    let name = (source as NSString).lastPathComponent
                    for seed in [hash, nil] as [String?] {
                        let identity = ShareNaming.identity(refKey: item.refKey, contentHash: seed)
                        paths.insert("\(folder)/\(ShareNaming.sharedFileName(sourceFileName: name, identity: identity))".lowercased())
                    }
                }
            }
        }
        await world.server.setProtectedContents(table)
        await world.server.setProtectedPaths(paths)
    }

    /// **中身を変える書き込み**の回数（コピー・アップロード・削除）。
    /// ⚠️ `create_folder` は数えない——既存フォルダに対しては 409＝無害だから。
    /// ただし「毎回投げている」こと自体は無駄なので `redundantFolderCreates` で別に見る。
    private func writeCount(_ world: World) async -> Int {
        await world.server.requestLog.filter {
            $0.contains("copy_batch") || $0.contains("delete_batch") || $0.contains("files/upload")
        }.count
    }

    /// 落ち着いたあとの 1 回の反映が投げる `create_folder` の数（0 であってほしい）。
    private func folderCreateCount(_ world: World) async -> Int {
        await world.server.requestLog.filter { $0.contains("create_folder") }.count
    }

    // MARK: - 操作

    private enum Operation: String, CaseIterable {
        case createSet, addItems, removeItems, updateMembers, deleteSet
        case externalDelete      // 家族が Dropbox 側で消した
        case copyFailure         // コピーが一時的に失敗する
        case slowJob             // ジョブがタイムアウト後に完走する（diagnostics-52 の形）
        case listFailure         // 一覧が取れない（通信断）
        case backupVanishes      // Backup の実物が消え、照合が記録を消した（ADR-278）
        // ── 追補 7: 世界を広げる操作 ──
        case recreateSet         // 消して、同じ名前・同じメンバーで作り直す（同じフォルダ名になる）
        case familyDrop          // 家族がセットのフォルダに写真を置いた（どこにも他に無い中身）
        case familyDropRetired   // 家族が、**消したセットの**まだ在るフォルダに写真を置いた
        case listContinueFailure // 一覧の 2 ページ目以降が取れない
        case metadataFailure     // 中身を訊く口（get_metadata）が一時的に失敗する
        case photoEdited         // 端末で写真が編集され、Backup の中身が変わった
        case cloudIndexRefresh   // アプリの同期一覧が追いついた（それまでは古い一覧のまま）
        case backupPass          // バックアップがもう一度走り、重複写真の記録を確かめ直した（持ち主が入れ替わる）
        case midSync             // **反映の途中**に、上のどれか（利用者・家族の操作）が割り込む
    }

    /// 反映の途中に割り込ませてよい操作（利用者と家族がすること）。
    nonisolated private static let interleavable: [Operation] = [
        .createSet, .addItems, .removeItems, .updateMembers, .deleteSet, .recreateSet,
        .familyDrop, .familyDropRetired, .photoEdited, .backupPass, .cloudIndexRefresh,
    ]

    /// 割り込みが本当に起きたか（10）。偽サーバーの口から書き、テストが読む。
    private actor HookProbe {
        var requests = 0
        var fired = false
        /// 反映が `after` 回の往復より前に終わった（短い反映）。不発でも網の故障ではない。
        func tick() -> Int { requests += 1; return requests }
        func markFired() { fired = true }
    }

    private func apply(_ op: Operation, world: inout World, rng: inout Seeded) async {
        await applyRaw(op, world: &world, rng: &rng)
        await refreshProtected(world)
    }

    private func applyRaw(_ op: Operation, world: inout World, rng: inout Seeded) async {
        let sets = await world.store.allShareSets()
        let allKeys = world.photos.keys.sorted()
        switch op {
        case .createSet:
            guard sets.count < 4 else { return }
            let n = rng.int(1..<min(6, allKeys.count + 1))
            var keys: [String] = []
            for _ in 0..<n { if let k = rng.pick(allKeys) { keys.append(k) } }
            _ = await world.engine.createSet(name: "Set\(rng.int(0..<3))",
                                             refKeys: Array(Set(keys)))
        case .addItems:
            guard let set = rng.pick(sets), let key = rng.pick(allKeys) else { return }
            _ = await world.engine.addItems(setID: set.id, refKeys: [key])
        case .removeItems:
            guard let set = rng.pick(sets) else { return }
            let items = await world.store.shareItems(setID: set.id)
            guard let victim = rng.pick(items) else { return }
            _ = await world.engine.removeItems(setID: set.id, refKeys: [victim.refKey])
        case .updateMembers:
            guard let set = rng.pick(sets) else { return }
            let n = rng.int(0..<min(5, allKeys.count + 1))
            var keys: [String] = []
            for _ in 0..<n { if let k = rng.pick(allKeys) { keys.append(k) } }
            _ = await world.engine.updateSetMembers(setID: set.id, refKeys: Array(Set(keys)))
        case .deleteSet:
            guard sets.count > 1, let set = rng.pick(sets) else { return }
            if let folder = SharePlanning.setFolderPath(
                shareRoot: ShareSettingsKeys.currentShareRoot(world.defaults),
                folderName: set.folderName, deviceFolder: nil) { world.retiredFolders.append(folder) }
            _ = await world.engine.deleteSet(id: set.id)
        case .externalDelete:
            let shared = await sharedPhotos(world)
            guard let path = rng.pick(shared.keys.sorted()) else { return }
            await world.server.remove(path)
        case .copyFailure:
            await world.server.inject(.init(endpoint: "copy_batch", times: 1, effect: .status(503)))
        case .slowJob:
            await world.server.setJobsTimeOutButComplete(true)
        case .listFailure:
            await world.server.inject(.init(endpoint: "files/list_folder", times: 1,
                                            effect: .status(503)))
        case .backupVanishes:
            guard let key = rng.pick(allKeys.filter { !world.vanished.contains($0) }),
                  let path = world.backupPaths[key] else { return }
            await world.server.remove(path)
            // 同じファイルを指す重複写真も、実物を失う。
            for (other, otherPath) in world.backupPaths where otherPath == path { world.vanished.insert(other) }
            world.vanished.insert(key)
            var remote: [String: String] = [:]
            for (other, otherPath) in world.backupPaths where !world.vanished.contains(other) {
                remote[otherPath.lowercased()] = world.photos[other]
            }
            _ = await world.store.reconcile(remote: remote, listedAt: Date().addingTimeInterval(60))
        case .recreateSet:
            guard sets.count > 1, let set = rng.pick(sets) else { return }
            let keys = await world.store.shareItems(setID: set.id).map(\.refKey)
            _ = await world.engine.deleteSet(id: set.id)
            _ = await world.engine.createSet(name: set.name, refKeys: keys)
        case .familyDropRetired:
            var folders: [String] = []
            for retired in world.retiredFolders where await world.server.entry(at: retired) != nil {
                folders.append(retired)
            }
            guard let folder = rng.pick(folders) else { return }
            world.familyDrops += 1
            await world.server.seed("\(folder)/family-\(world.familyDrops).jpg",
                                    hash: "family\(world.familyDrops)")
        case .familyDrop:
            // 置き先は、いまのセットのフォルダか、**消したセットのまだ在るフォルダ**
            // （フォルダごと消す前に一覧を取り直さないと、ここに置いた写真ごと消える・追補 3）。
            var folders = sets.compactMap {
                SharePlanning.setFolderPath(shareRoot: ShareSettingsKeys.currentShareRoot(world.defaults),
                                            folderName: $0.folderName, deviceFolder: nil)
            }
            for retired in world.retiredFolders where await world.server.entry(at: retired) != nil {
                folders.append(retired)
            }
            guard let folder = rng.pick(folders) else { return }
            world.familyDrops += 1
            await world.server.seed("\(folder)/family-\(world.familyDrops).jpg",
                                    hash: "family\(world.familyDrops)")
        case .listContinueFailure:
            await world.server.inject(.init(endpoint: "files/list_folder/continue", times: 1,
                                            effect: .status(503)))
        case .metadataFailure:
            await world.server.inject(.init(endpoint: "files/get_metadata", times: 2,
                                            effect: .status(503)))
        case .photoEdited:
            guard let key = rng.pick(allKeys.filter { !world.vanished.contains($0) }),
                  let path = world.backupPaths[key] else { return }
            world.edits += 1
            let hash = "e\(world.edits)-\(world.photos[key] ?? "")"
            world.photos[key] = hash
            // 重複写真の片方を編集したら、もう片方とは別の中身＝別のファイルになる。
            let shared = world.backupPaths.filter { $0.key != key && $0.value == path }.isEmpty == false
            if shared {
                let edited = (path as NSString).deletingPathExtension + "-edited\(world.edits).jpg"
                world.backupPaths[key] = edited
                await world.server.seed(edited, hash: hash)
                _ = await world.store.upsertRecord(dropboxPath: edited, localIdentifier: String(key.dropFirst(2)),
                                                   filename: (edited as NSString).lastPathComponent,
                                                   creationDate: nil, contentHash: hash,
                                                   people: [], albums: [], isFavorite: false)
                world.analysis.photos[key] = hash
                return
            }
            await world.server.seed(path, hash: hash)
            _ = await world.store.upsertRecord(dropboxPath: path, localIdentifier: String(key.dropFirst(2)),
                                               filename: (path as NSString).lastPathComponent,
                                               creationDate: nil, contentHash: hash,
                                               people: [], albums: [], isFavorite: false)
            world.analysis.photos[key] = hash
        case .backupPass:
            _ = await backupPass(world: &world, rng: &rng)
        case .cloudIndexRefresh:
            await world.cloudIndex.refresh(from: world.server)
        case .midSync:
            break   // `runMidSync` が扱う（反映を伴うので、ここでは何もしない）
        }
    }

    /// バックアップの 1 回ぶん（本番の runner と同じ決め方）: **記録に無い写真だけ**を上げる。
    /// 同じ名前・同じ中身のファイルが既に在れば 409 → 中身が同じ → 記録を書く（持ち主になる）。
    /// - Returns: 上げに行った枚数（＝本体の転送）。落ち着いた後は 0 でなければならない（11）。
    ///
    /// ⚠️ 追補 7 より前の世界にはバックアップが無かった。重複写真の片方が記録の持ち主から外れると、
    /// 次の回にその片方が「未バックアップ」になって上げ直し、今度はもう片方が外れる——
    /// この往復（ADR-278 追補 2）は**共有の反映ではなくバックアップの側**で起きるので、
    /// 共有の書き込みだけを数える 1 / 9 には原理的に見えなかった。
    private func backupPass(world: inout World, rng: inout Seeded) async -> Int {
        let recorded = await world.store.recordedLocalIdentifiers()
        var pending = world.backupPaths.keys.filter {
            !world.vanished.contains($0) && !recorded.contains(String($0.dropFirst(2)))
        }.sorted()
        if rng.chance(50) { pending.reverse() }
        for key in pending {
            guard let path = world.backupPaths[key] else { continue }
            if await world.server.entry(at: path) == nil {
                await world.server.seed(path, hash: world.photos[key] ?? "")
            }
            _ = await world.store.upsertRecord(dropboxPath: path, localIdentifier: String(key.dropFirst(2)),
                                               filename: (path as NSString).lastPathComponent,
                                               creationDate: nil, contentHash: world.photos[key],
                                               people: [], albums: [], isFavorite: false)
        }
        return pending.count
    }

    /// 反映の途中（`after` 回目の往復の直後）に `op` を割り込ませ、その反映を走らせる。
    /// - Returns: 割り込みが起きたか／起きなかったなら、その反映の往復の数。
    private func runMidSync(_ op: Operation, after: Int, world: inout World,
                            rng: inout Seeded) async -> (fired: Bool, requests: Int) {
        let probe = HookProbe()
        // ⚠️ 割り込みの中身（どのセット・どの写真か）は、反映を始める**前**に決められない
        // （セットが反映の途中で変わる）。乱数は種から作り直す＝再現できる。
        let innerSeed = rng.next()
        let box = WorldBox(world)
        await world.server.setRequestHook { [box] _ in
            guard await probe.tick() == after else { return }
            await probe.markFired()
            await MainActor.run {}   // 次の await から MainActor で動く
            await box.apply(op, seed: innerSeed, test: self)
        }
        await world.engine.syncNow()
        await world.server.setRequestHook(nil)
        world = box.world
        return (await probe.fired, await probe.requests)
    }

    /// 割り込みの中から `World`（値）を書き換えるための入れ物。
    @MainActor private final class WorldBox {
        var world: World
        init(_ world: World) { self.world = world }
        func apply(_ op: Operation, seed: UInt64, test: ShareInvariantTests) async {
            var rng = Seeded(seed: seed)
            var copy = world
            await test.apply(op, world: &copy, rng: &rng)
            world = copy
        }
    }

    /// 健全なサーバーに戻して、収束するまで反映する。
    ///
    /// ⚠️ **走行中なら待ってから次を投げる**。`syncNow` は走行中の呼び出しを
    /// 「あとで 1 回だけ再走」に畳むので、待たずに連打すると**ほとんどが空振りする**
    /// ——最初はそれで 12 回のうち 4 回しか走っておらず、収束していないのを
    /// 実装のせいだと読み違えた。
    private func settle(_ world: World, rounds: Int = 10) async {
        await world.server.clearFaults()
        await world.server.setJobsTimeOutButComplete(false)
        for _ in 0..<rounds {
            await quiesce(world)
            await world.engine.syncNow()
        }
        await quiesce(world)
    }

    /// 予約された反映（`scheduleSync` の投げっぱなし Task）が片付くまで待つ。
    private func quiesce(_ world: World) async {
        for _ in 0..<2_000 where world.engine.isSyncing {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: - 不変条件

    private func checkInvariants(_ world: World, seed: UInt64, trace: [String]) async {
        let sets = await world.store.allShareSets()
        let dump = await sharedPhotos(world).sorted { $0.key < $1.key }
            .map { "\(($0.key as NSString).lastPathComponent)=\($0.value)" }
        let memberDump = await members(world).values.map { $0.values.sorted() }
        let context = """

            種=\(seed)
            操作列: \(trace.joined(separator: " → "))
            セット: \(sets.map(\.folderName))
            メンバー: \(memberDump)
            実在: \(dump)
            通信: copy=\(await world.server.requestLog.filter { $0.contains("copy_batch") }.count)             delete=\(await world.server.requestLog.filter { $0.contains("delete_batch") }.count)             list=\(await world.server.requestLog.filter { $0.contains("files/list_folder") }.count)             mkdir=\(await world.server.requestLog.filter { $0.contains("create_folder") }.count)
            """
        let membersBySet = await members(world)
        let memberHashes = Set(membersBySet.values.flatMap { $0.values }.filter { !$0.isEmpty })
        let wantedHashes = await resolvableMemberHashes(world)
        let shared = await sharedPhotos(world)
        let presentHashes = shared.values.filter { !$0.isEmpty }

        // 2. メンバーの中身が失われていない。
        for hash in wantedHashes {
            #expect(presentHashes.contains(hash),
                    "メンバーの写真が共有フォルダに無い（hash=\(hash)）\(context)")
        }
        // 4. 孤児が無い（メンバーでない写真が残っていない）。
        for (path, hash) in shared where !hash.isEmpty {
            #expect(memberHashes.contains(hash),
                    "どのセットのメンバーでもない写真が残っている（\(path)）\(context)")
        }
        // 3. 重複が無い（セットごとに同じ hash は 1 つ）。
        for set in await world.store.allShareSets() {
            guard let folder = SharePlanning.setFolderPath(
                shareRoot: ShareSettingsKeys.currentShareRoot(world.defaults),
                folderName: set.folderName, deviceFolder: nil)?.lowercased() else { continue }
            let inFolder = shared.filter { $0.key.hasPrefix(folder + "/") }
            // ⚠️ 「同じ中身は 1 つ」ではなく「**メンバーの数まで**」。端末に中身もファイル名も同じ写真が
            //    2 枚あり両方をセットに入れたら、コピーは写真ごとに 1 つ（名前の印が写真ごとに違う）。
            //    重複写真を世界に入れる前（追補 7 より前）は、この 2 つの規則を区別できなかった。
            var allowed: [String: Int] = [:]
            for item in await world.store.shareItems(setID: set.id) {
                if let hash = world.photos[item.refKey] { allowed[hash, default: 0] += 1 }
            }
            var placed: [String: [String]] = [:]
            for (path, hash) in inFolder where !hash.isEmpty { placed[hash, default: []].append(path) }
            for (hash, paths) in placed {
                #expect(paths.count <= max(1, allowed[hash] ?? 0),
                        "同じ写真がメンバーの数より多い（\(paths.sorted()) hash=\(hash) メンバー \(allowed[hash] ?? 0)）\(context)")
            }
        }
        // 5. 受信側が復元できる（記録のある全メンバーの解析データが、そのセットのフォルダに在る）。
        // ⚠️ `decodeValidated` は使わない——この世界の hash（`h0` など）は 64 桁でないので捨てられる。
        for set in await world.store.allShareSets() {
            guard let folder = SharePlanning.setFolderPath(
                shareRoot: ShareSettingsKeys.currentShareRoot(world.defaults),
                folderName: set.folderName, deviceFolder: nil)?.lowercased() else { continue }
            let prefix = "\(folder)/\(ShareAnalysisData.subfolderName)/"
            var analysed = Set<String>()
            for path in await world.server.filePaths() where path.hasPrefix(prefix) {
                guard let body = await world.server.body(at: path),
                      let file = try? JSONDecoder().decode(ShareAnalysisData.File.self, from: body) else { continue }
                analysed.formUnion(file.entries.keys)
            }
            let items = await world.store.shareItems(setID: set.id)
            let refs = await world.store.backupRefs(forLocalIdentifiers: items.map { String($0.refKey.dropFirst(2)) })
            for item in items where refs[String(item.refKey.dropFirst(2))] != nil {
                guard let hash = world.photos[item.refKey] else { continue }
                #expect(analysed.contains(hash.lowercased()),
                        "メンバーの解析データが無い（\(set.folderName) hash=\(hash)）\(context)")
            }
        }
        // 6. 実在を知らずに書かない（途中の回も含めて・ADR-277）。
        let conflicts = await world.server.conflictedCopyEntries
        #expect(conflicts == 0,
                "既に在る宛先へコピーを投げた（\(conflicts) 件）——一覧の失敗を空と読んでいないか\(context)")

        // 7. 最後の 1 枚を消さない（途中の回も含めて・ADR-278）。
        let lastCopies = await world.server.deletedLastCopies
        let lastCopyPaths = await world.server.deletedLastCopyPaths
        #expect(lastCopies == 0,
                "中身がどこにも残らない削除をした（\(lastCopyPaths)）\(context)")

        // 7'. 消えてよい場所（他の端末の共有コピー）しか残らない削除をしない（追補 7）。
        let durable = await world.server.deletedLastDurableCopies
        let durablePaths = await world.server.deletedLastDurableCopyPaths
        #expect(durable == 0,
                "他の端末の共有コピーしか残らない削除をした（\(durablePaths)）——共有のコピーを証拠に数えていないか\(context)")

        // 8. いまのメンバーを消さない（途中の回も含めて・追補 7）。
        let removedMembers = await world.server.removedProtectedCopies
        var removedMemberPaths = await world.server.removedProtectedCopyPaths
        if removedMembers > 0, let at = await world.server.removedProtectedAtRequest.first {
            let log = await world.server.requestLog
            let window = log.enumerated().filter { $0.offset >= at - 12 && $0.offset < at }
                .map { "\($0.offset + 1):\(($0.element as NSString).lastPathComponent)" }
            removedMemberPaths.append("直前の往復: \(window.joined(separator: " "))")
        }
        #expect(removedMembers == 0,
                "消した時点でメンバーだった写真を、セットのフォルダから消した／移した（\(removedMemberPaths)）——古い計画のまま書いていないか\(context)")

        // 1 / 9. 収束（さらに 2 回反映しても書き込みが起きない）。
        for round in 1...2 {
            let before = await writeCount(world)
            await world.engine.syncNow()
            let after = await writeCount(world)
            #expect(after == before,
                    "収束していない（\(round) 回目の追加の反映で書き込み \(after - before) 件）\(context)")
        }
    }

    /// 11. **バックアップも落ち着く**: 1 回走らせて残りを済ませたら、次の回は 1 枚も上げない。
    private func checkBackupSettles(_ world: inout World, rng: inout Seeded, seed: UInt64,
                                    trace: [String]) async {
        _ = await backupPass(world: &world, rng: &rng)
        for round in 1...2 {
            let uploads = await backupPass(world: &world, rng: &rng)
            #expect(uploads == 0,
                    "バックアップが落ち着かない（\(round) 回目に \(uploads) 枚を上げ直した）——重複写真の持ち主が入れ替わっていないか 種=\(seed) 操作列: \(trace.joined(separator: " → "))")
        }
    }

    // MARK: - 本体

    /// 種ごとの操作の選び方。⚠️ 操作の**種類**は専用の乱数で選ぶ（引数の乱数と分ける）
    /// ——こうすると `operationsAreAllExercised` が反映を回さずに同じ列を再生できる。
    private struct Script {
        var picker: Seeded
        let seed: UInt64
        var midSyncs = 0
        init(seed: UInt64) { self.seed = seed; picker = Seeded(seed: seed ^ 0x5EED_0F_0B5) }
        mutating func nextOperation() -> Operation { picker.pick(Operation.allCases)! }
        /// 割り込む操作は**種で順に回す**（乱数で選ぶと、操作を 1 つ足すたびにどれかが選ばれなくなった
        /// ——実際に 2 回 `operationsAreAllExercised` が落ちた）。種 1〜n の最初の割り込みで全部が出る。
        mutating func interleaved() -> Operation {
            let list = ShareInvariantTests.interleavable
            defer { midSyncs += 1 }
            return list[(Int(seed % UInt64(list.count)) + midSyncs) % list.count]
        }
        /// 何回目の往復の直後に割り込むか。⚠️ 反映の往復の数は状況で 3〜100 と振れるので、
        /// 大きい数だけだと短い反映で不発になる（不発は何も試していない）。半分は早い窓に置く。
        mutating func trigger() -> Int { picker.chance(50) ? picker.int(1..<4) : picker.int(4..<12) }
        mutating func syncAfter() -> Bool { picker.chance(70) }
    }

    nonisolated private static let seeds = Array<UInt64>(1...32)
    private static let operationsPerSeed = 16

    @Test("ランダムな操作列のあと、反映は収束して不変条件を満たす", arguments: seeds)
    func convergesUnderRandomOperations(seed: UInt64) async {
        var rng = Seeded(seed: seed)
        var script = Script(seed: seed)
        var world = await makeWorld(photoCount: 8, seed: seed)
        var trace: [String] = []

        // まず 1 セット作って土台にする（重複写真の組 p0/p8 を両方入れる）。
        _ = await world.engine.createSet(name: "Set0", refKeys: ["L-p0", "L-p1", "L-p8", "L-p2"])
        trace.append("createSet(Set0)")
        await refreshProtected(world)
        await world.engine.syncNow()

        var unfired: [String] = []
        var fired = 0
        for _ in 0..<Self.operationsPerSeed {
            let op = script.nextOperation()
            if op == .midSync {
                let inner = script.interleaved()
                let after = script.trigger()
                let result = await runMidSync(inner, after: after, world: &world, rng: &rng)
                trace.append("midSync(\(inner.rawValue)@\(after)\(result.fired ? "" : "・不発 \(result.requests) 往復"))")
                if result.fired { fired += 1 }
                // ⚠️ 往復が足りていたのに発火しない＝口が壊れている（短い反映の不発は故障ではない）。
                else if result.requests >= after { unfired.append("\(inner.rawValue)@\(after)") }
                continue
            }
            await apply(op, world: &world, rng: &rng)
            trace.append(op.rawValue)
            // 操作のたびに反映を 1 回だけ回す（途中経過は壊れていてよい）。
            if script.syncAfter() { await world.engine.syncNow() }
        }

        await settle(world)

        await checkInvariants(world, seed: seed, trace: trace)
        await checkBackupSettles(&world, rng: &rng, seed: seed, trace: trace)
        // 10. 往復が足りていたのに割り込みが起きない、は網の故障（何も試していない）。
        #expect(unfired.isEmpty, "反映の途中の割り込みが起きなかった（\(unfired)）種=\(seed)")
        await Self.coverage.add(firedMidSyncs: fired)
    }

    /// 種の全体で、割り込みが何回発火したか（並列に走っても数えられるように actor）。
    private actor Coverage {
        var firedMidSyncs = 0
        func add(firedMidSyncs n: Int) { firedMidSyncs += n }
    }
    private static let coverage = Coverage()

    /// 10. 反映の途中の割り込みは、決まった形で**必ず**効く（種まかせにしない）。
    /// 1 往復目の直後にセットを作り直すと、反映は古い計画で書かずに見送り（名指しのログ）、
    /// 次の反映で中身を失わずに落ち着く。
    @Test("反映の途中でセットを作り直しても、そのセットの写真を消さない（決まった割り込み）")
    func midSyncRecreateIsHandled() async {
        var rng = Seeded(seed: 99)
        var world = await makeWorld(photoCount: 8, seed: 99)
        let name = "Recreate-\(UUID().uuidString.prefix(6))"
        _ = await world.engine.createSet(name: name, refKeys: ["L-p0", "L-p1", "L-p8"])
        let other = "Other-\(UUID().uuidString.prefix(6))"
        _ = await world.engine.createSet(name: other, refKeys: ["L-p2"])
        await refreshProtected(world)
        await world.engine.syncNow()
        let tap = DiagnosticsLog.shared.tap()
        var fired = false
        for after in 1...6 {
            let result = await runMidSync(.recreateSet, after: after, world: &world, rng: &rng)
            fired = fired || result.fired
        }
        #expect(fired, "割り込みが一度も起きなかった（何も試していない）")
        await settle(world)
        await checkInvariants(world, seed: 99, trace: ["midSync(recreateSet@1...6)"])
        let skipped = await tap.lines().filter {
            $0.contains("反映の途中でセットかメンバーが変わった") && ($0.contains(name) || $0.contains(other))
        }
        #expect(!skipped.isEmpty,
                "途中の作り直しを見送りで受けていない（別の仕組みで通っている）")
    }

    /// 消したセットのフォルダを片付ける反映の**途中**に、家族がそのフォルダへ写真を置く（追補 3 の形）。
    /// ⚠️ 種まかせでは、消した直後の 1 回の反映の、一覧と削除の間に置く並びがほとんど出ない
    /// （M4＝取り直しを外す変異が、乱数の網では 32 種とも緑だった）。割り込む位置を総当たりする。
    @Test("消したセットのフォルダを片付ける途中に置かれた写真を、フォルダごと消さない", arguments: Array(1...10))
    func familyDropIntoRetiredFolderMidSync(after: Int) async {
        var rng = Seeded(seed: 7)
        var world = await makeWorld(photoCount: 8, seed: 700 + UInt64(after))
        let gone = await world.engine.createSet(name: "Gone-\(UUID().uuidString.prefix(6))", refKeys: ["L-p4", "L-p5"])
        _ = await world.engine.createSet(name: "Stay-\(UUID().uuidString.prefix(6))", refKeys: ["L-p0"])
        await refreshProtected(world)
        await world.engine.syncNow()
        guard let gone, let set = await world.store.allShareSets().first(where: { $0.id == gone }),
              let folder = SharePlanning.setFolderPath(shareRoot: ShareSettingsKeys.currentShareRoot(world.defaults),
                                                       folderName: set.folderName, deviceFolder: nil) else {
            Issue.record("前提: セットが作れていない"); return
        }
        world.retiredFolders.append(folder)
        _ = await world.engine.deleteSet(id: gone)
        await refreshProtected(world)
        let dropsBefore = world.familyDrops
        let result = await runMidSync(.familyDropRetired, after: after, world: &world, rng: &rng)
        await settle(world)
        await checkInvariants(world, seed: 700 + UInt64(after),
                              trace: ["deleteSet", "midSync(familyDropRetired@\(after)・\(result.fired ? "発火" : "不発 \(result.requests) 往復"))"])
        // 置けた回（フォルダがまだ在った回）は、置いた写真が Dropbox のどこかに残っている。
        if world.familyDrops > dropsBefore {
            let kept = await world.server.filePaths().contains { $0.hasSuffix("/family-1.jpg") }
            #expect(kept, "家族が置いた写真が Dropbox のどこにも無い（after=\(after)）")
        }
    }

    /// 10. 操作の種類は、種の全体でどれも選ばれる（足した操作が一度も走らない網にしない）。
    @Test("どの操作も、どれかの種で選ばれる（割り込みの中身も含めて）")
    func operationsAreAllExercised() {
        var picked = Set<Operation>()
        var interleaved = Set<Operation>()
        for seed in Self.seeds {
            var script = Script(seed: seed)
            for _ in 0..<Self.operationsPerSeed {
                let op = script.nextOperation()
                picked.insert(op)
                if op == .midSync {
                    interleaved.insert(script.interleaved())
                    _ = script.trigger()
                } else {
                    _ = script.syncAfter()
                }
            }
        }
        #expect(picked == Set(Operation.allCases), "選ばれない操作: \(Set(Operation.allCases).subtracting(picked))")
        #expect(interleaved == Set(Self.interleavable),
                "割り込みで選ばれない操作: \(Set(Self.interleavable).subtracting(interleaved))")
    }
}
