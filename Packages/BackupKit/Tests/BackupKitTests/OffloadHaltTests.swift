import DropboxCore
import Foundation
import Testing
@testable import BackupKit

/// **オフロードの緊急停止**（ADR-202）。
///
/// オフロード済み＝端末の原本は消してあるので、クラウドのコピーが**唯一のコピー**。
/// それが Dropbox 側で消された／差し替えられたら、その写真はもう戻らない。
/// できるのは「同じことを繰り返させない」ことだけなので、
///   1. 検知する（照合の一覧と台帳を突き合わせる）
///   2. 自動オフロードを**その場で止める**
///   3. 利用者が**「確認した」を押すまで**、自動オフロードを設定させない
/// の 3 つを守る。
///
/// ⚠️ 設定を勝手に変える処理なので、**誤発動は許されない**。実在する写真を「消えた」と
/// 読まないこと（不完全な一覧では判定しないこと）も併せて確かめる。
@Suite("オフロードの緊急停止", .serialized)
struct OffloadHaltTests {

    private let root = "/MosaicPhotos/iPhone-E7/Backup"
    private let photo = Data("only-copy".utf8)

    private func storeWithOffloaded(paths: [String]) async -> BackupStore {
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        _ = await store.upsertOffloads(paths.map {
            (localIdentifier: "ID-\($0)", dropboxPath: $0, albums: ["旅行"],
             captureDate: Date(timeIntervalSince1970: 1_700_000_000),
             contentHash: DropboxContentHash.hash(of: photo))
        })
        return store
    }

    private func cleanDefaults() {
        OffloadHalt.resetForTesting()
        UserDefaults.standard.removeObject(forKey: BackupSettingsKeys.offloadAutoThresholdMB)
    }

    // MARK: - 検知

    @Test("実体が消えたオフロード済み写真を見つける")
    func detectsMissingCopies() async {
        let path = "\(root)/2023/2023-11/a.jpg"
        let store = await storeWithOffloaded(paths: [path])

        let missing = await store.missingOffloadedPaths(remote: [:])   // Dropbox に何も無い

        // ⚠️ 台帳もリモート一覧（`path_lower`）も小文字。突合は小文字で揃える。
        #expect(missing == [path.lowercased()], "唯一のコピーが消えているのに気づいていない")
    }

    /// ⚠️ **差し替え**も「その写真は無い」。同じ名前で別の中身になっていたら、
    /// 元の写真はもう取り出せない。
    @Test("中身が差し替えられた写真も、失われたものとして扱う")
    func detectsReplacedCopies() async {
        let path = "\(root)/2023/2023-11/a.jpg"
        let store = await storeWithOffloaded(paths: [path])

        let missing = await store.missingOffloadedPaths(
            remote: [path.lowercased(): DropboxContentHash.hash(of: Data("different".utf8))])

        #expect(missing == [path.lowercased()], "別物に差し替わっているのに在ると判定した")
    }

    /// ⚠️ **誤発動を防ぐ**。実在していれば当然何も起きない。
    @Test("実体が在るなら何も検知しない")
    func detectsNothingWhenPresent() async {
        let path = "\(root)/2023/2023-11/a.jpg"
        let store = await storeWithOffloaded(paths: [path])

        let missing = await store.missingOffloadedPaths(
            remote: [path.lowercased(): DropboxContentHash.hash(of: photo)])

        #expect(missing.isEmpty, "在る写真を消えたと判定した（緊急停止の誤発動）")
    }

    // MARK: - 停止・確認

    @Test("検知したら自動オフロードが「オフロードしない」へ落ちる")
    func recordingHaltTurnsAutoOffloadOff() {
        cleanDefaults()
        defer { cleanDefaults() }
        UserDefaults.standard.set(500, forKey: BackupSettingsKeys.offloadAutoThresholdMB)

        #expect(OffloadHalt.record(missingPaths: ["/a.jpg", "/b.jpg"]))

        #expect(UserDefaults.standard.integer(forKey: BackupSettingsKeys.offloadAutoThresholdMB) == 0,
                "自動オフロードが止まっていない（同じことを繰り返す）")
        #expect(OffloadHalt.isHalted)
        #expect(OffloadHalt.current?.missingCount == 2)
        #expect(OffloadHalt.current?.samplePaths == ["/a.jpg", "/b.jpg"])
    }

    /// ⚠️ 「確認した」を押すまでは知らせが消えないこと。**再起動しても残る**
    /// （UserDefaults に持つ）——読まないまま消えると、止めた理由が伝わらない。
    @Test("確認するまで知らせは消えない")
    func noticeSurvivesUntilAcknowledged() {
        cleanDefaults()
        defer { cleanDefaults() }
        OffloadHalt.record(missingPaths: ["/a.jpg"])

        #expect(OffloadHalt.isHalted, "前提: 止まっている")
        OffloadHalt.acknowledge()
        #expect(!OffloadHalt.isHalted, "確認しても知らせが消えない")
        #expect(OffloadHalt.current == nil)
    }

    /// ⚠️ 確認しても**自動オフロードは戻さない**。戻すかどうかは利用者が決める
    /// （原因が分からないまま再開させない）。
    @Test("確認しても、自動オフロードは自動では戻らない")
    func acknowledgingDoesNotResumeAutoOffload() {
        cleanDefaults()
        defer { cleanDefaults() }
        UserDefaults.standard.set(500, forKey: BackupSettingsKeys.offloadAutoThresholdMB)
        OffloadHalt.record(missingPaths: ["/a.jpg"])

        OffloadHalt.acknowledge()

        #expect(UserDefaults.standard.integer(forKey: BackupSettingsKeys.offloadAutoThresholdMB) == 0,
                "確認しただけで自動オフロードが復活した（利用者が選んでいない）")
    }

    /// 2 度目の検知は、件数だけ新しくする（最初に止めた時刻は動かさない）。
    @Test("停止中にまた見つかっても、止めた時刻は動かない")
    func secondDetectionKeepsTheOriginalTime() {
        cleanDefaults()
        defer { cleanDefaults() }
        let first = Date(timeIntervalSince1970: 1_000_000)
        #expect(OffloadHalt.record(missingPaths: ["/a.jpg"], at: first))
        #expect(!OffloadHalt.record(missingPaths: ["/a.jpg", "/b.jpg"], at: Date()),
                "新しい停止として扱っている（同じ停止の続きのはず）")

        #expect(OffloadHalt.current?.haltedAt == first)
        #expect(OffloadHalt.current?.missingCount == 2, "件数が新しくなっていない")
    }

    @Test("見つからなければ何も起きない（設定も触らない）")
    func noDetectionLeavesEverythingAlone() {
        cleanDefaults()
        defer { cleanDefaults() }
        UserDefaults.standard.set(500, forKey: BackupSettingsKeys.offloadAutoThresholdMB)

        #expect(!OffloadHalt.record(missingPaths: []))

        #expect(!OffloadHalt.isHalted)
        #expect(UserDefaults.standard.integer(forKey: BackupSettingsKeys.offloadAutoThresholdMB) == 500,
                "何も起きていないのに設定を書き換えた")
    }
}
