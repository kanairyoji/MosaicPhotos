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

    @Test("取り出したら、送信済みの分はもう出てこない")
    func takeAllThenSendClearsTheQueue() {
        let (s, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(s.appendEntry(shard: "2026-09", path: "/a.jpg", entry: entry(["太郎"])))
        let taken = s.takeAll()
        #expect(taken["2026-09"]?.count == 1, "取り出せていない")
        #expect(s.save([:]))          // 全部送れた＝残す分は無い
        #expect(s.load().isEmpty, "送信済みの分が残っている（次回に二重送信される）")
    }

    /// 送れなかった分は本体へ残り、ジャーナルを畳んでも失われないこと。
    @Test("送れなかった分は本体に残る")
    func failedEntriesSurviveTakeAll() {
        let (s, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(s.appendEntry(shard: "2026-09", path: "/a.jpg", entry: entry(["太郎"])))
        _ = s.takeAll()
        #expect(s.save(["2026-09": ["/a.jpg": entry(["太郎"])]]))   // 送信失敗ぶんを本体へ
        #expect(s.load()["2026-09"]?["/a.jpg"]?.people == ["太郎"], "再送分が失われている")
    }

    /// ⚠️ **送信中に届いた行を落とさない**（ADR-200）。旧実装は「読む → 送る →
    /// ジャーナルをファイルごと消す」で、その間に背景アップロードの完了が追記した行が
    /// 巻き添えで消えていた。写真の実体は上がって完了記録が付くので、その人物名・
    /// アルバム・位置情報は**二度と作られない**。
    @Test("取り出した後に届いた行は、次の取り出しで出てくる")
    func entriesAppendedDuringSendSurvive() {
        let (s, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(s.appendEntry(shard: "2026-09", path: "/a.jpg", entry: entry(["太郎"])))
        let taken = s.takeAll()                       // ← 送信のために取り出した
        #expect(taken["2026-09"]?["/a.jpg"] != nil)

        // 送信している最中に、背景アップロードの完了が 1 件届いた。
        #expect(s.appendEntry(shard: "2026-09", path: "/b.jpg", entry: entry(["花子"])))
        #expect(s.save([:]))                          // 取り出した分は全部送れた

        let next = s.takeAll()
        #expect(next["2026-09"]?["/b.jpg"]?.people == ["花子"],
                "送信中に届いた行が消えている（その写真のメタデータは二度と作られない）")
        #expect(next["2026-09"]?["/a.jpg"] == nil, "送信済みの行まで出てきている（二重送信）")
    }

    /// ⚠️ **本命の回帰テスト**（ADR-200）。旧実装は「読む → 送る → ジャーナルをファイルごと
    /// 消す」で、読んでから消すまでの**隙間に届いた行が巻き添えで消えていた**。背景アップロードの
    /// 完了通知は実行中ずっと届き続けるので、この隙間は現実に踏む。
    ///
    /// ここでは取り出しと追記を**本当に並行させて**、1 行も失われないことを確かめる。
    /// 取り出しが「読む」と「消す」の 2 段に分かれていると（＝錠が無いと）、
    /// その間に入った追記が消えて件数が合わなくなる。
    @Test("取り出しと追記が並行しても、1 行も失われない")
    func concurrentAppendsAreNeverLost() async {
        let (s, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let total = 200

        /// 取り出した行を集める（取り出しは複数回走る）。
        actor Collected {
            private(set) var paths: Set<String> = []
            func add(_ payload: PendingMetadataStore.Payload) {
                for (_, entries) in payload { paths.formUnion(entries.keys) }
            }
        }
        let collected = Collected()

        await withTaskGroup(of: Void.self) { group in
            // 書き手: 1 枚ごとに 1 行を追記する（背景アップロードの完了通知に相当）。
            group.addTask {
                for i in 0..<total {
                    #expect(s.appendEntry(shard: "2026-09", path: "/p\(i).jpg", entry: entry(["太郎"])))
                }
            }
            // 読み手: 送信のために繰り返し取り出す。
            group.addTask {
                for _ in 0..<40 {
                    await collected.add(s.takeAll())
                    #expect(s.save([:]))       // 取り出した分は送れたことにする
                    await Task.yield()
                }
            }
        }
        // 走り切ったあとに残っている分も回収する。
        await collected.add(s.takeAll())

        let paths = await collected.paths
        #expect(paths.count == total,
                """
                \(total - paths.count) 行が失われた。
                その写真の人物名・アルバム・位置情報は二度と作られない（実体は上がって
                完了記録が付くので、次回の対象にならない）。
                """)
    }

    /// ⚠️ **同じ行を 1 回の実行で 2 度送らない**。旧実装は実行の前半（背景経路の先出し）と
    /// 後半（`writeMetadata`）の両方が `load()` していて、前半がジャーナルを消さないため
    /// 同じ行が 2 回流れていた。
    @Test("続けて取り出しても、同じ行は 2 度出てこない")
    func takeAllIsNotRepeatable() {
        let (s, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(s.appendEntry(shard: "2026-09", path: "/a.jpg", entry: entry(["太郎"])))
        _ = s.takeAll()
        #expect(s.save([:]))                          // 送れた分を消す
        #expect(s.takeAll().isEmpty, "同じ行がもう一度出てきた（1 回の実行で 2 度送る）")
    }
}
