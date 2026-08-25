import DropboxCore
import Foundation
import Testing
@testable import BackupKit

/// 照合（reconcile）の安全性（レビュー指摘）。
///
/// ⚠️ 照合は「リモート一覧を取る」→「記録と突き合わせる」の 2 段階で、前者は再帰ページングの
/// ため実写真数によっては数秒〜数十秒かかる。その間にバックアップが 1 枚上げて記録を追加すると、
/// そのパスは**古い一覧に無い**ので従来実装は記録を削除していた。その後 runner が当該 ID を
/// 進捗台帳へ保存すると、次回は済み判定で除外されて記録が自己修復せず、その写真は共有・
/// オフロード・バックアップアルバムのどこからも辿れなくなる。
@Suite("Reconcile safety")
struct ReconcileSafetyTests {

    private func makeStore() -> BackupStore {
        BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
    }

    /// 記録の時刻順を確実に分けるための微小待ち（Date() の分解能に頼らない）。
    private func tick() async {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }

    @Test("一覧取得後に上がった写真の記録は、古い一覧で削除されない")
    func recordCreatedAfterListingSurvives() async {
        let store = makeStore()
        // 一覧取得の時点で既にある記録（リモートにも実在する）。
        _ = await store.upsertRecord(dropboxPath: "/b/old.jpg", localIdentifier: "id-old",
                                     filename: "old.jpg", creationDate: nil, contentHash: "h-old",
                                     people: [], albums: ["旅行"], isFavorite: false)
        await tick()

        // ここでリモート一覧を取り始める（この内容が固定される）。
        let listedAt = Date()
        let remote = ["/b/old.jpg": "h-old"]

        // 一覧取得中にバックアップが 1 枚アップロードして記録を追加した。
        await tick()
        _ = await store.upsertRecord(dropboxPath: "/b/new.jpg", localIdentifier: "id-new",
                                     filename: "new.jpg", creationDate: nil, contentHash: "h-new",
                                     people: [], albums: ["旅行"], isFavorite: false)

        let (verified, removed) = await store.reconcile(remote: remote, listedAt: listedAt)

        #expect(removed == 0, "一覧が知り得なかった新しい記録を削除した")
        let paths = await store.allRecordsLite().map(\.dropboxPath).sorted()
        #expect(paths == ["/b/new.jpg", "/b/old.jpg"], "照合後に新しい記録が消えた")
        #expect(verified.contains("id-new"),
                "台帳に載らない＝バッジ・済み判定から漏れる（次回の再アップロード対象にもならない）")
        #expect(verified.contains("id-old"))

        // 記録が残るので、共有・オフロード・アルバム集計からも脱落しない。
        let summary = await store.albumSummary()
        #expect(summary.recordCount == 2)
        #expect(summary.albums.first(where: { $0.name == "旅行" })?.photoCount == 2)
        #expect(await store.localToCloudPaths()["id-new"] == "/b/new.jpg")

        // 台帳（＝verified）に載るので、次回バックアップでは済みとして除外される
        //（記録が消えていた場合は「済み ID なのに記録なし」で永久に脱落していた）。
        let pending = BackupPlanning.pendingUploads(
            allIdentifiers: ["id-old", "id-new"], alreadyUploaded: verified, limit: 0)
        #expect(pending.pending.isEmpty)
    }

    @Test("一覧より前の記録でリモートに実体が無いものは削除される（照合本来の働き）")
    func staleRecordIsRemoved() async {
        let store = makeStore()
        _ = await store.upsertRecord(dropboxPath: "/b/gone.jpg", localIdentifier: "id-gone",
                                     filename: "gone.jpg", creationDate: nil, contentHash: "h1",
                                     people: [], albums: [], isFavorite: false)
        await tick()
        let listedAt = Date()

        let (verified, removed) = await store.reconcile(remote: [:], listedAt: listedAt)

        #expect(removed == 1)
        #expect(verified.isEmpty)
        #expect(await store.allRecordsLite().isEmpty)
    }

    @Test("一覧より前の記録で content_hash が食い違うものは削除される（別物を信用しない）")
    func hashMismatchRecordIsRemoved() async {
        let store = makeStore()
        _ = await store.upsertRecord(dropboxPath: "/b/a.jpg", localIdentifier: "id-a",
                                     filename: "a.jpg", creationDate: nil, contentHash: "h-local",
                                     people: [], albums: [], isFavorite: false)
        await tick()
        let listedAt = Date()

        let (verified, removed) = await store.reconcile(remote: ["/b/a.jpg": "h-other"],
                                                        listedAt: listedAt)

        #expect(removed == 1)
        #expect(verified.isEmpty)
        #expect(await store.allRecordsLite().isEmpty)
    }
}

// MARK: - 排他（照合中にバックアップを始めない）

/// ⚠️ 照合は `phase` を触らないため、実行中も `isRunning` は false のまま。別画面のボタンも
/// 夜間の自動起動も素通りし、指摘の順序（照合の一覧取得中にアップロード）が実際に起きる。
@Suite("Reconcile exclusion")
@MainActor
struct ReconcileExclusionTests {

    @Test("照合中はバックアップを開始しない")
    func backupDoesNotStartWhileReconciling() {
        let engine = BackupEngine(auth: DropboxAuthService(appKey: "k", redirectURI: "app://cb"))
        engine.setReconcilingForTesting(true)
        #expect(engine.isBusy, "照合中が busy として見えていない")

        engine.start(folder: "/Backup")
        #expect(engine.phase == .idle, "照合中なのにバックアップが始まった")

        engine.setReconcilingForTesting(false)
        #expect(!engine.isBusy)
        engine.cancel()
    }
}
