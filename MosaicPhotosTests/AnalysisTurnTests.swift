import Testing
@testable import MosaicPhotos

/// **顔とタグ/埋め込みを同じ枠で同時に起こさない**（ADR-237）。
///
/// ⚠️ 実機ログ diagnostics-97 で、CLIP の画像塔・顔モデル・Vision が同時に常駐し
/// 14 秒で +248MB・最大 823MB まで上がっていた。ANE ゲートは「同時に 1 つ**推論**しない」
/// ための仕掛けで、「同時に 1 つ**載せる**」は誰も見ていなかった。
@Suite("解析の順番（顔とタグ/埋め込みを重ねない）")
struct AnalysisTurnTests {

    @Test("タグ/埋め込みが走っている間は、顔を起こさない")
    func doesNotStartFacesWhileTagging() {
        #expect(AnalysisTurn.next(facesRunning: false, tagsRunning: true,
                                 faceScanPossible: true, lastChoice: .tags) == .none)
    }

    @Test("顔が走っている間は、タグ/埋め込みを起こさない")
    func doesNotStartTagsWhileScanningFaces() {
        #expect(AnalysisTurn.next(facesRunning: true, tagsRunning: false,
                                 faceScanPossible: true, lastChoice: .faces) == .none)
    }

    /// ⚠️ 交互にしないと、顔に常に残作業がある状況（新しい写真が毎日入る）で
    /// タグ/埋め込みが**永久に走らない**。
    @Test("どちらも止まっていれば、前回と違う方を起こす（交互）")
    func alternatesWhenBothIdle() {
        #expect(AnalysisTurn.next(facesRunning: false, tagsRunning: false,
                                 faceScanPossible: true, lastChoice: .faces) == .tags)
        #expect(AnalysisTurn.next(facesRunning: false, tagsRunning: false,
                                 faceScanPossible: true, lastChoice: .tags) == .faces)
        // 初回（まだ何も起こしていない）は顔から。
        #expect(AnalysisTurn.next(facesRunning: false, tagsRunning: false,
                                 faceScanPossible: true, lastChoice: .none) == .faces)
    }

    /// ⚠️⚠️ **残作業の数で顔を止めない**（実装中に一度そう書いて気づいた）。
    /// `faceBacklog` は一度測ったらスキャン側しか更新しないので、0 になったあと新しい写真が
    /// 入っても 0 のまま——それを「仕事が無い」と読むと**顔スキャンが永久に走らなくなる**。
    /// この関数が受けるのは「モデルが同梱されているか」だけで、仕事の有無は起こされた側が見る。
    @Test("顔に残作業が無くても順番は回ってくる（永久に止まらない）")
    func facesKeepGettingTurnsEvenWhenIdle() {
        // 「仕事が無い」を表す引数は無い＝止める手段が無い、が正しい形。
        var last = AnalysisTurn.Choice.tags
        let turn = AnalysisTurn.next(facesRunning: false, tagsRunning: false,
                                    faceScanPossible: true, lastChoice: last)
        #expect(turn == .faces)
        last = turn
        #expect(AnalysisTurn.next(facesRunning: false, tagsRunning: false,
                                 faceScanPossible: true, lastChoice: last) == .tags)
    }

    @Test("顔が走り得ないならタグ/埋め込み（顔の順番で空回りしない）")
    func fallsBackToTagsWhenFacesCannotRun() {
        #expect(AnalysisTurn.next(facesRunning: false, tagsRunning: false,
                                 faceScanPossible: false, lastChoice: .tags) == .tags)
        #expect(AnalysisTurn.next(facesRunning: false, tagsRunning: false,
                                 faceScanPossible: false, lastChoice: .faces) == .tags)
    }

    /// ⚠️ 交互は**両方に順番が回ること**が肝。10 回まわして片方が 0 回にならないこと。
    @Test("繰り返しても、どちらも飢えない")
    func neitherStarves() {
        var last = AnalysisTurn.Choice.none
        var counts: [AnalysisTurn.Choice: Int] = [:]
        for _ in 0..<10 {
            let turn = AnalysisTurn.next(facesRunning: false, tagsRunning: false,
                                        faceScanPossible: true, lastChoice: last)
            counts[turn, default: 0] += 1
            last = turn
        }
        #expect(counts[.faces] == 5, "\(counts)")
        #expect(counts[.tags] == 5, "\(counts)")
    }
}
