import Foundation
import Testing
@testable import BackupKit

/// 共有写真の撮影日（ADR-199）。
/// 実フィードバック「共有フォルダの表示が撮影時間順でない。Dropbox へのアップロード順になっている？」
/// 受信側が見られる日付は Dropbox の `time_taken ?? client_modified` だけで、共有コピーは
/// サーバーサイドコピーなので `time_taken` が付かず、反映時刻＝アップロード順に並んでいた。
@Suite("共有写真の撮影日（ADR-199）")
struct SharedCaptureDateTests {

    private var validHash: String { String(repeating: "ab", count: 32) }
    private var otherHash: String { String(repeating: "cd", count: 32) }

    private func file(entries: [String: ShareAnalysisData.Entry],
                      versions: ShareAnalysisData.Versions
                        = .init(tag: 1, perception: 1, face: 1)) -> ShareAnalysisData.File {
        ShareAnalysisData.File(versions: versions, entries: entries)
    }

    // MARK: - 解析データ（送受信の器）

    @Test("撮影日は往復しても保たれる")
    func captureDateRoundTrips() {
        let taken = Date(timeIntervalSince1970: 1_600_000_000)
        let original = file(entries: [validHash: .init(tags: ["beach"],
                                                       d: taken.timeIntervalSince1970)])
        let decoded = ShareAnalysisData.decodeValidated(ShareAnalysisData.encode(original)!)
        #expect(decoded?.entries[validHash]?.d == taken.timeIntervalSince1970)
    }

    @Test("撮影日だけのエントリも捨てられない（並び順はそれだけで直せる）")
    func dateOnlyEntrySurvives() {
        let entry = ShareAnalysisData.Entry(d: 1_600_000_000)
        let decoded = ShareAnalysisData.decodeValidated(ShareAnalysisData.encode(file(entries: [validHash: entry]))!)
        #expect(decoded?.entries[validHash]?.d == 1_600_000_000,
                "解析が無くても撮影日だけは届かないと並べられない")
    }

    @Test("NaN・非現実的な撮影日は「日付なし」へ落ちる")
    func implausibleDatesDropped() {
        // ⚠️ 素通しにすると並べ替えの strict weak ordering が壊れる（顔の時期分割で実際に踏んだ）。
        // JSON は NaN/Inf を表現できないので、検証そのものを直接突く。
        for bad in [Double.nan, .infinity, -.infinity, -1e300, 1e300, 9_999_999_999_999] {
            let cleaned = ShareAnalysisData.validate(.init(tags: ["keep"], d: bad))
            #expect(cleaned?.tags == ["keep"])
            #expect(cleaned?.d == nil, "不正な撮影日 \(bad) が残った")
        }
    }

    @Test("非現実的な撮影日はファイル経由でも落ちる")
    func implausibleDatesDroppedThroughFile() {
        let entry = ShareAnalysisData.Entry(tags: ["keep"], d: 9_999_999_999_999)
        let decoded = ShareAnalysisData.decodeValidated(
            ShareAnalysisData.encode(file(entries: [validHash: entry]))!)
        #expect(decoded?.entries[validHash]?.tags == ["keep"])
        #expect(decoded?.entries[validHash]?.d == nil)
    }

    // MARK: - 受信側の取り込み計画

    @Test("撮影日はモデル版が食い違っても取り込む")
    func captureDatesIgnoreVersionGates() {
        // 送信側の版が全部違う＝タグ・CLIP・顔は 1 件も取り込まれない状況。
        // それでも「いつ撮ったか」はモデルに依存しない事実なので、並び順は直せる。
        let entry = ShareAnalysisData.Entry(tags: ["beach"], d: 1_600_000_000)
        let data = file(entries: [validHash: entry],
                        versions: .init(tag: 99, perception: 99, face: 99))
        let batch = ShareImportPlanning.plan(
            analysisData: data,
            localItems: [.init(refKey: "C-/family/set/a.jpg", contentHash: validHash)],
            versions: .init(tag: 1, perception: 1, face: 1))

        #expect(batch.tags.isEmpty, "版が違うのにタグが入った")
        #expect(batch.captureDates.count == 1)
        #expect(batch.captureDates.first?.date == Date(timeIntervalSince1970: 1_600_000_000))
    }

    @Test("突合できない写真の撮影日は返さない")
    func unmatchedPhotosProduceNoDates() {
        let data = file(entries: [validHash: .init(d: 1_600_000_000)])
        let batch = ShareImportPlanning.plan(
            analysisData: data,
            localItems: [.init(refKey: "C-/family/set/a.jpg", contentHash: otherHash)],
            versions: .init(tag: 1, perception: 1, face: 1))
        #expect(batch.captureDates.isEmpty)
    }

    // MARK: - 受信側の表（純ロジック）

    private func date(_ epoch: Double) -> Date { Date(timeIntervalSince1970: epoch) }

    @Test("新しく届いた撮影日が勝つ")
    func newerValueWins() {
        let merged = SharedCaptureDateStore.merged(
            existing: ["/family/a.jpg": date(100)],
            adding: ["/family/a.jpg": date(200)],
            keeping: nil)
        #expect(merged["/family/a.jpg"] == date(200))
    }

    @Test("パスは小文字で揃える（表示側が引く形に合わせる）")
    func pathsAreLowercased() {
        let merged = SharedCaptureDateStore.merged(
            existing: [:], adding: ["/Family/Set/A.JPG": date(100)], keeping: nil)
        #expect(merged["/family/set/a.jpg"] == date(100))
    }

    @Test("keeping に無いパスの記録は捨てる")
    func prunesMissingPaths() {
        let merged = SharedCaptureDateStore.merged(
            existing: ["/family/gone.jpg": date(100), "/family/here.jpg": date(200)],
            adding: [:],
            keeping: ["/family/here.jpg"])
        #expect(merged.keys.sorted() == ["/family/here.jpg"])
    }

    @Test("keeping が nil の回は掃除しない（一覧が取れなかった回に全消ししない）")
    func keepsEverythingWhenNoKeepSet() {
        let merged = SharedCaptureDateStore.merged(
            existing: ["/family/a.jpg": date(100)], adding: [:], keeping: nil)
        #expect(merged.count == 1)
    }

    /// ⚠️ 残す向きは**古い方**。撮影日を落とした写真は Dropbox の日付（≒提供者が反映した時刻）に
    /// 落ちるので、古い写真ほど上書きの価値が高い——古い方を捨てると何年も前の写真が
    /// 列の末尾（最新側）へ飛び、元の不具合より悪くなる。
    @Test("上限を超えたら古い撮影日から残す")
    func capsToOldest() {
        var existing: [String: Date] = [:]
        let over = SharedCaptureDateStore.maxEntries + 50
        for i in 0..<over { existing["/family/\(i).jpg"] = date(Double(i)) }
        let merged = SharedCaptureDateStore.merged(existing: existing, adding: [:], keeping: nil)
        #expect(merged.count == SharedCaptureDateStore.maxEntries)
        // 捨てられた範囲を**全部**確かめる（並べ替えずに prefix する退行を確実に落とす）。
        for i in SharedCaptureDateStore.maxEntries..<over {
            #expect(merged["/family/\(i).jpg"] == nil, "新しい側が残った: \(i)")
        }
        // 残った範囲も端まで確かめる。
        #expect(merged["/family/0.jpg"] != nil)
        #expect(merged["/family/\(SharedCaptureDateStore.maxEntries - 1).jpg"] != nil)
    }

    // MARK: - 永続化（ファイルへの往復）

    @Test("保存した撮影日を読み直せる")
    func roundTripsThroughTheFile() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SharedCaptureDateStore(directory: dir, filename: "dates.json")
        #expect(store.load().isEmpty, "まだ何も書いていないのに読めた")

        let saved = store.record(["/Family/Set/A.JPG": date(1_600_000_000)])
        #expect(saved.table["/family/set/a.jpg"] == date(1_600_000_000))
        #expect(!saved.saveFailed && saved.droppedByCap.isEmpty, "収まったのに失敗扱いになった")

        // 別インスタンスで読み直す＝本番と同じ経路（起動をまたぐ）。
        let reopened = SharedCaptureDateStore(directory: dir, filename: "dates.json")
        #expect(reopened.load() == ["/family/set/a.jpg": date(1_600_000_000)],
                "保存した撮影日が読み直せない＝並びが黙って直らない")
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("書けない場所でも落ちない（撮影日が無いだけ）")
    func survivesAnUnwritableLocation() {
        // 実在するファイルをディレクトリとして使う＝書き込みが必ず失敗する。
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        let store = SharedCaptureDateStore(directory: file, filename: "dates.json")
        let outcome = store.record(["/family/a.jpg": date(100)])
        // 戻り値は**実際に残っているもの**を返す（書けなかったのに入ったように見せない）。
        #expect(outcome.table.isEmpty, "書けていないのに入ったと報告した")
        #expect(store.load().isEmpty, "書けていないのに読めた")
        // ⚠️ 保存できなかった回は**やり直す価値がある**失敗として報告する。
        #expect(outcome.saveFailed, "保存できなかったのに成功と報告した＝永久に失う")
        try? FileManager.default.removeItem(at: file)
    }

    @Test("上限に当たって入らなかった受信ぶんは「落ちた」と報告する")
    func reportsIncomingDatesThatDidNotFit() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SharedCaptureDateStore(directory: dir, filename: "dates.json")

        // 古い側で表を埋めきる。
        var old: [String: Date] = [:]
        for i in 0..<SharedCaptureDateStore.maxEntries { old["/family/old\(i).jpg"] = date(Double(i)) }
        _ = store.record(old)

        // そこへ「新しい」写真が届く＝古い側を残す規則なので入らない。
        let outcome = store.record(["/family/new.jpg": date(9_000_000_000)])
        #expect(outcome.table["/family/new.jpg"] == nil, "上限を超えて入ってしまった")
        // ⚠️ 上限は**やり直しても同じ**。保存の失敗と混ぜてはいけない——混ぜると
        // その解析データが永久に取り込み済みにならず、取得の上限を食い潰して
        // その先のシャードが一つも取れなくなる。
        #expect(outcome.droppedByCap == ["/family/new.jpg"])
        #expect(!outcome.saveFailed, "上限を保存失敗として報告した＝取り込みが止まる")
        try? FileManager.default.removeItem(at: dir)
    }

    /// 回帰: 書けなかったのに「入った」と誤認しないこと。
    /// 存在の有無だけを見ると、前回の**古い値**が残っているキーを入ったと数えてしまう。
    // MARK: - 取得の順送り（飢餓を作らない）

    /// 回帰: 1 回の取得数に上限を付けたことで、**先頭に居座る候補が後ろを飢えさせない**こと。
    /// 候補から外れるのは「取り込み済み」を記録できたときだけで、その条件は何度も
    /// 続けて満たされないことがある。毎回先頭から取ると 49 個目以降は一度も取れない。
    @Test("続きから取るので、候補が一巡する")
    func rotationVisitsEveryCandidate() {
        let all = (0..<10).map { String(format: "/f/shard-%02d.json", $0) }
        // 印が無ければ先頭から。
        #expect(ShareAnalysisFetch.rotated(all, after: nil) == all)
        // 印の次から始まり、末尾まで行ったら先頭へ回り込む。
        let fromThird = ShareAnalysisFetch.rotated(all, after: all[2])
        #expect(fromThird.first == all[3])
        #expect(fromThird.count == all.count)
        #expect(Set(fromThird) == Set(all), "一巡で全部を訪れない")
        // 上限 4 で 3 回回せば、10 個のうち 10 個すべてを訪れる。
        var cursor: String? = nil
        var visited: Set<String> = []
        for _ in 0..<3 {
            let window = ShareAnalysisFetch.rotated(all, after: cursor).prefix(4)
            visited.formUnion(window)
            cursor = window.last
        }
        #expect(visited.count == all.count, "3 回回しても訪れていない候補がある: \(all.count - visited.count) 個")
        // 末尾を過ぎた印でも先頭へ戻る（候補が減ったときに止まらない）。
        #expect(ShareAnalysisFetch.rotated(all, after: "/f/shard-99.json") == all)
    }

    /// ⚠️ この 2 本は**一度ひっくり返して戻した**規則を固定する。読まずに変えないこと。
    /// 印を「取れたところまで」にすると取り込みが丸ごと止まり（下の 1 本目）、
    /// 予算を「試した数」で数えると 1 件も取れない回に印だけ進む（2 本目）。
    @Test("印は試したところまで進む（先頭が恒久的に失敗しても止まらない）")
    func cursorAdvancesPastPermanentFailures() {
        let all = (0..<10).map { String(format: "/f/shard-%02d.json", $0) }
        // 先頭 3 個が必ず失敗する共有フォルダ。
        let deadPrefix: Set<String> = [all[0], all[1], all[2]]

        var cursor: String? = nil
        var everFetched: Set<String> = []
        for _ in 0..<4 {
            let plan = ShareAnalysisFetch.planRun(
                rotated: ShareAnalysisFetch.rotated(all, after: cursor),
                budget: 4, failureStreakLimit: 5,
                outcome: { !deadPrefix.contains($0) })
            everFetched.formUnion(plan.attempted.filter { !deadPrefix.contains($0) })
            #expect(plan.cursor != nil, "1 件も試さずに終わった＝止まっている")
            cursor = plan.cursor
        }
        #expect(everFetched == Set(all).subtracting(deadPrefix),
                "壊れた先頭の後ろが取れていない: \(Set(all).subtracting(deadPrefix).subtracting(everFetched))")
    }

    @Test("予算は取れた数で数える（1 件も取れない回に印を使い切らない）")
    func budgetCountsSuccessesNotAttempts() {
        let all = (0..<20).map { String(format: "/f/shard-%02d.json", $0) }
        // 全部失敗する回（圏外・レート制限）。
        let plan = ShareAnalysisFetch.planRun(rotated: all, budget: 8, failureStreakLimit: 5,
                                              outcome: { _ in false })
        #expect(plan.attempted.count == 5,
                "連続失敗で畳まず \(plan.attempted.count) 件叩いた")
        // 全部成功する回は予算ちょうどで止まる。
        let full = ShareAnalysisFetch.planRun(rotated: all, budget: 8, failureStreakLimit: 5,
                                              outcome: { _ in true })
        #expect(full.attempted.count == 8)
        // 途中で 1 件だけ落ちても、予算は減らない（9 件試して 8 件取れる）。
        let one = all[3]
        let mixed = ShareAnalysisFetch.planRun(rotated: all, budget: 8, failureStreakLimit: 5,
                                               outcome: { $0 != one })
        #expect(mixed.attempted.count == 9, "失敗で予算が減った")
        #expect(mixed.cursor == all[8])
    }

    // MARK: - 受信側の読み取り能力の版

    /// ⚠️ 解析データから新しく読む項目を足したら、この版を必ず上げる。上げないと、
    /// 旧ビルドで取り込んだ rev が「取り込み済み」のまま残り、新項目は永久に届かない。
    @Test("撮影日を読むビルドは受信能力の版が 2 以上")
    func capabilityVersionCoversCaptureDates() {
        #expect(ShareAnalysisFetch.receiverCapabilityVersion >= 2)
    }

    @Test("読み込みでも不正な epoch は落とす")
    func loadRejectsImplausibleEpochs() {
        #expect(SharedCaptureDateStore.date(from: .nan) == nil)
        #expect(SharedCaptureDateStore.date(from: 1e300) == nil)
        #expect(SharedCaptureDateStore.date(from: 1_600_000_000) == date(1_600_000_000))
    }
}
