import Foundation
import Testing
@testable import BackupKit
import DropboxCore

/// メタデータ再送キューの**追記ジャーナル**（ADR-171）。
///
/// ⚠️ 旧実装はメタデータを実行の最後にまとめて送っていた。夜間ウィンドウは毎回 expired で
/// 終わるので、**途中終了するとそれまでの全件が失われる**——しかも写真本体は進捗台帳に載って
/// 次回の対象から外れるため、人物名・アルバム・位置情報は二度と作られない。
/// 1 枚ごとに追記して、完了記録より先に永続化する。
@Suite("メタデータの追記ジャーナル")
struct PendingMetadataJournalTests {

    private func store() -> (PendingMetadataStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (PendingMetadataStore(directory: dir, filename: "queue.json"), dir)
    }

    private func entry(_ people: [String]) -> DropboxBackupMetadata.Entry {
        DropboxBackupMetadata.Entry(people: people, albums: [], isFavorite: false,
                                    date: nil, contentHash: "h", localIdentifier: "L",
                                    latitude: nil, longitude: nil, isScreenshot: false)
    }

    @Test("追記した分は、本体を書かなくても読み戻せる（＝途中終了でも残る）")
    func journalSurvivesWithoutSave() {
        let (s, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(s.appendEntry(shard: "2026-09", path: "/a.jpg", entry: entry(["太郎"])))
        #expect(s.appendEntry(shard: "2026-09", path: "/b.jpg", entry: entry(["花子"])))
        // save() は一度も呼んでいない＝実行が途中で落ちた状況。
        let loaded = s.load()
        #expect(loaded["2026-09"]?.count == 2, "途中終了で失われている: \(loaded)")
        #expect(loaded["2026-09"]?["/a.jpg"]?.people == ["太郎"])
    }

    @Test("本体とジャーナルは合わさり、ジャーナルが後勝ち")
    func journalWinsOverBase() {
        let (s, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(s.save(["2026-09": ["/a.jpg": entry(["古い"])]]))
        #expect(s.appendEntry(shard: "2026-09", path: "/a.jpg", entry: entry(["新しい"])))
        #expect(s.load()["2026-09"]?["/a.jpg"]?.people == ["新しい"], "古い値が勝っている")
    }

    /// ⚠️ 1 行の破損で残り全部を失わないこと（途中終了はファイル末尾を壊し得る）。
    @Test("壊れた行は読み飛ばし、残りは生かす")
    func brokenLineIsSkipped() throws {
        let (s, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(s.appendEntry(shard: "2026-09", path: "/a.jpg", entry: entry(["太郎"])))
        // 途中で電源が落ちた形（末尾の行が途切れる）。
        let journal = dir.appendingPathComponent("queue.jsonl")
        let data = try Data(contentsOf: journal) + Data("{\"shard\":\"2026-09\",\"pa".utf8)
        try data.write(to: journal)

        let loaded = s.load()
        #expect(loaded["2026-09"]?.count == 1, "壊れた行のせいで健全な行まで失っている")
        #expect(loaded["2026-09"]?["/a.jpg"]?.people == ["太郎"])
    }

    @Test("送信が確認できたらジャーナルを消す")
    func clearAfterSend() {
        let (s, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(s.appendEntry(shard: "2026-09", path: "/a.jpg", entry: entry(["太郎"])))
        #expect(s.save([:]))          // 全部送れた＝残す分は無い
        s.clearJournal()
        #expect(s.load().isEmpty, "送信済みの分が残っている（次回に二重送信される）")
    }

    /// 送れなかった分は本体へ残り、ジャーナルを消しても失われないこと。
    @Test("送れなかった分は本体に残る")
    func failedEntriesSurviveJournalClear() {
        let (s, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(s.appendEntry(shard: "2026-09", path: "/a.jpg", entry: entry(["太郎"])))
        #expect(s.save(["2026-09": ["/a.jpg": entry(["太郎"])]]))   // 送信失敗ぶんを本体へ
        s.clearJournal()
        #expect(s.load()["2026-09"]?["/a.jpg"]?.people == ["太郎"], "再送分が失われている")
    }
}
