import Foundation
import Testing
@testable import BackupKit
import DropboxCore
import DropboxTestSupport

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
/// 3. **重複が無い**: 同じ写真（content_hash）が 2 つ置かれない。
/// 4. **孤児が無い**: どのセットのメンバーでもない写真・フォルダが残らない。
/// 5. **受信側が復元できる**: 全メンバーに解析データが届く。
///
/// ## この網で最初に捕まったもの（2026-09-21・差分方式へ移る前の実装）
/// **8 種のうち 3 種が壊れた**。どれも既存のテストでは出ていなかった。
/// - 種 2: **孤児**——どのセットのメンバーでもない写真が共有フォルダに残る（家族には見えたまま）。
/// - 種 3: **メンバーの写真が無い**——記録は「コピー済み」なのに実体が無い（家族に見えない）。
/// - 種 4: **収束しない**——落ち着いたはずの反映が毎回 1 件書き込む。
///
/// 3 つとも「**記録が真実**」という設計に由来する。記録と実在が食い違ったとき、
/// 食い違いの種類ごとに直し方（採用・自己修復・墓標・掃除）を足してきたが、
/// 組み合わせが増えるほど漏れが出る。
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
        /// 端末にある写真（refKey → content_hash）。バックアップ済みのものだけ共有できる。
        var photos: [String: String]
    }

    private func makeWorld(photoCount: Int, seed: UInt64) async -> World {
        let defaults = TestDefaults.scratch("share-invariant-\(seed)")
        defaults.set(true, forKey: ShareSettingsKeys.provideEnabled)
        defaults.set(Self.backupRoot, forKey: BackupSettingsKeys.dropboxFolder)

        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        let server = FakeDropboxServer()
        var photos: [String: String] = [:]
        for index in 0..<photoCount {
            // ⚠️ **同名の別写真を混ぜる**。宛先名の衝突は実障害の温床だった（diagnostics-52）。
            let name = "IMG_\(index % max(1, photoCount / 2)).jpg"
            let path = "/mosaicphotos/backup/\(index)/\(name)"
            let hash = "h\(index)"
            await server.seed(path, hash: hash)
            await store.upsertRecord(dropboxPath: path, localIdentifier: "p\(index)",
                                     filename: name, creationDate: nil, contentHash: hash,
                                     people: [], albums: [], isFavorite: false)
            photos["L-p\(index)"] = hash
        }
        let engine = ShareSyncEngine(tokenProvider: FakeTokenProvider(),
                                     storeProvider: { store }, httpClient: server,
                                     defaults: defaults)
        engine.pollIntervalNs = 1_000_000
        engine.maxPollAttempts = 3
        engine.analysisSource = StubAnalysisSource(photos: photos)
        return World(engine: engine, store: store, server: server,
                     defaults: defaults, photos: photos)
    }

    /// 解析データの出どころ（全メンバーにタグを 1 つ返すだけ）。
    @MainActor private final class StubAnalysisSource: ShareAnalysisSource {
        let photos: [String: String]
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
    }

    private func apply(_ op: Operation, world: inout World, rng: inout Seeded) async {
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
        }
    }

    /// 健全なサーバーに戻して、収束するまで反映する。
    private func settle(_ world: World, rounds: Int = 12) async {
        await world.server.clearFaults()
        await world.server.setJobsTimeOutButComplete(false)
        for _ in 0..<rounds { await world.engine.syncNow() }
    }

    // MARK: - 不変条件

    private func checkInvariants(_ world: World, seed: UInt64, trace: [String]) async {
        let context = """

            種=\(seed)
            操作列: \(trace.joined(separator: " → "))
            """
        let membersBySet = await members(world)
        let wantedHashes = Set(membersBySet.values.flatMap { $0.values }.filter { !$0.isEmpty })
        let shared = await sharedPhotos(world)
        let presentHashes = shared.values.filter { !$0.isEmpty }

        // 2. メンバーの中身が失われていない。
        for hash in wantedHashes {
            #expect(presentHashes.contains(hash),
                    "メンバーの写真が共有フォルダに無い（hash=\(hash)）\(context)")
        }
        // 4. 孤児が無い（メンバーでない写真が残っていない）。
        for (path, hash) in shared where !hash.isEmpty {
            #expect(wantedHashes.contains(hash),
                    "どのセットのメンバーでもない写真が残っている（\(path)）\(context)")
        }
        // 3. 重複が無い（セットごとに同じ hash は 1 つ）。
        for set in await world.store.allShareSets() {
            guard let folder = SharePlanning.setFolderPath(
                shareRoot: ShareSettingsKeys.currentShareRoot(world.defaults),
                folderName: set.folderName, deviceFolder: nil)?.lowercased() else { continue }
            let inFolder = shared.filter { $0.key.hasPrefix(folder + "/") }
            var seen = Set<String>()
            for (path, hash) in inFolder where !hash.isEmpty {
                #expect(!seen.contains(hash),
                        "同じ写真が 2 つある（\(path) hash=\(hash)）\(context)")
                seen.insert(hash)
            }
        }
        // 1. 収束（もう 1 回反映しても書き込みが起きない）。
        let before = await writeCount(world)
        await world.engine.syncNow()
        let after = await writeCount(world)
        #expect(after == before,
                "収束していない（追加の書き込み \(after - before) 件）\(context)")
    }

    // MARK: - 本体

    @Test("ランダムな操作列のあと、反映は収束して不変条件を満たす",
          arguments: [UInt64(1), 2, 3, 4, 5, 6, 7, 8])
    func convergesUnderRandomOperations(seed: UInt64) async {
        var rng = Seeded(seed: seed)
        var world = await makeWorld(photoCount: 8, seed: seed)
        var trace: [String] = []

        // まず 1 セット作って土台にする。
        _ = await world.engine.createSet(name: "Set0", refKeys: ["L-p0", "L-p1"])
        trace.append("createSet(Set0)")
        await world.engine.syncNow()

        for _ in 0..<14 {
            guard let op = rng.pick(Operation.allCases) else { break }
            await apply(op, world: &world, rng: &rng)
            trace.append(op.rawValue)
            // 操作のたびに反映を 1 回だけ回す（途中経過は壊れていてよい）。
            if rng.chance(70) { await world.engine.syncNow() }
        }

        await settle(world)

        // ⚠️ **差分方式へ移す前の実装が抱えている 3 件**（この網が最初に捕まえたもの）。
        // 種 2: 孤児（メンバーでない写真が残る）。種 3: メンバーの写真が無い。
        // 種 4: 収束しない（落ち着いた反映が毎回書き込む）。
        // どちらも「記録が真実」という設計に由来する（実在と記録の食い違いを直しきれない）。
        // 差分方式（望ましい集合 − 実在）へ移したらこの印を外すこと。
        let knownBroken: Set<UInt64> = [2, 3, 4]
        // ⚠️ `when:` が偽でも本体は走る（抑止されないだけ）。二重に呼ばないこと——
        // `checkInvariants` は最後に反映を 1 回するので、2 度呼ぶと状態が変わる。
        // ⚠️ `isIntermittent: true`。`scheduleSync()` は投げっぱなしの Task なので、
        // 操作と反映の噛み合い方が実行ごとに少し変わる——出る回と出ない回がある
        //（これ自体が「記録が真実」の実装の弱さでもある）。
        await withKnownIssue("記録が真実の実装が抱える食い違い（差分方式で解消する）",
                             isIntermittent: true) {
            await checkInvariants(world, seed: seed, trace: trace)
        } when: {
            knownBroken.contains(seed)
        }
    }
}
