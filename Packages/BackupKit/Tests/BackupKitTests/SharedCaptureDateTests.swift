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
        #expect(saved["/family/set/a.jpg"] == date(1_600_000_000))

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
        let table = store.record(["/family/a.jpg": date(100)])
        #expect(table["/family/a.jpg"] == date(100), "戻り値は混ぜた結果を返すべき")
        #expect(store.load().isEmpty, "書けていないのに読めた")
        try? FileManager.default.removeItem(at: file)
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
