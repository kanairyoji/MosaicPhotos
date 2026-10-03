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

    /// ⚠️⚠️ **明け渡しは順番の外**（レビューで見つけた・2026-09-29）。
    /// ADR-237 で「順番が `.tags` のときだけ `restartBackgroundFill()`」と書いたが、
    /// `next` は**タグが走っていれば `.none`** を返すので、「眠ったままフラグを握っている実行を
    /// 明け渡させる」という夜間の枠の逃げ道が、**まさにその状況で消えていた**
    /// ——前面で始まった実行が `waitWhilePaused`（最大 60 秒）で止まったまま `isTagging` を握り、
    /// 枠（約 77 秒）が丸ごと空転する（diagnostics-38 で踏んだ形そのもの）。
    @Test("窓・ブースト終了は、順番が .none でも滞留したタグを明け渡させる")
    func privilegedTriggerPreemptsStalledTags() {
        // 枠が来た。タグは走っている（ように見えるが眠っている）＝ next は .none。
        let turn = AnalysisTurn.next(facesRunning: false, tagsRunning: true,
                                    faceScanPossible: true, lastChoice: .faces)
        #expect(turn == .none, "fixture: この状況で .none にならないと、このテストは何も見ていない")
        #expect(AnalysisTurn.preemptsStalledTags(isPrivilegedTrigger: true, turn: turn,
                                                 tagsRunning: true),
                "枠が来たのに明け渡させない（77 秒の枠が丸ごと空転する）")
    }

    @Test("普通の契機では明け渡させない（走っている実行を横から止めない）")
    func ordinaryTriggerDoesNotPreempt() {
        #expect(!AnalysisTurn.preemptsStalledTags(isPrivilegedTrigger: false, turn: .none,
                                                  tagsRunning: true))
    }

    @Test("順番がタグなら二重に明け渡させない（通常の経路が restart を呼ぶ）")
    func noDoublePreemptWhenTurnIsTags() {
        #expect(!AnalysisTurn.preemptsStalledTags(isPrivilegedTrigger: true, turn: .tags,
                                                  tagsRunning: true))
    }

    @Test("タグが走っていないなら明け渡すものが無い")
    func nothingToPreemptWhenTagsAreIdle() {
        #expect(!AnalysisTurn.preemptsStalledTags(isPrivilegedTrigger: true, turn: .faces,
                                                  tagsRunning: false))
    }
}

/// **候補を列挙する前に「変わり得たか」を見る**（ADR-247・実機ログ diagnostics-102）。
///
/// ⚠️⚠️ **なぜテストで見逃したか**（ここが本題）。
/// 候補の列挙は `analysisCandidates`（PhotosFeatureKit）、呼ぶのは `AnalysisDriver`（アプリ層）。
/// どちらにもテストはあるが、**費用は 2 つの境界をまたいだ向こう側**に居た:
/// - `AnalysisDriverPolicy` のテストは「起こしてよいか」を見る＝*入口の可否*。
/// - 顔側のテストは「渡された候補」に対する振る舞いを見る＝*候補を作る費用はテストの外*。
/// - ⚠️ そして `analysisCandidates` は `@MainActor` の top-level 関数で、PHPhotoLibrary に
///   触るためユニットテストが書かれていない。**誰の責任範囲でもない場所に 11 秒が居た。**
///
/// 1 回の呼び出しとしてはどれも正しく、「**毎回払う必要があるのか**」を問うテストが無かった。
/// ADR-244 の「2 回目をテストする」と同じ穴の、*費用*版。
/// → だから判断（指紋が同じなら飛ばす）を純 enum へ出して、ここで固定する。
@Suite("候補の列挙を飛ばしてよい条件（ADR-247）")
struct CandidateEnumerationGateTests {

    private func fp(cloud: Int = 7, local: Int = 18_204,
                    scanned: Int = 86_771, unreadable: Int = 1)
        -> CandidateEnumerationGate.Fingerprint {
        .init(cloudRevision: cloud, localCount: local, scanned: scanned, unreadable: unreadable)
    }

    @Test("記録が無ければ必ず列挙する（初回から飛ばさない）")
    func firstRunAlwaysEnumerates() {
        #expect(!CandidateEnumerationGate.canSkip(fp(), last: nil))
    }

    /// ⚠️ 実機で 11 回ぶん払っていたぶん（1 回 約 11 秒）。
    @Test("4 つの数が全部同じなら飛ばす")
    func skipsWhenNothingMoved() {
        #expect(CandidateEnumerationGate.canSkip(fp(), last: fp()))
    }

    /// ⚠️⚠️ **ここが本丸**。ADR-243 でこれを「次の一手」に残したときの懸念は
    /// 「半端にやると**変わったのに気づかない**側の不具合になる」だった。
    /// 母集合が動く 4 つの経路すべてで、必ず列挙し直すことを固定する。
    @Test("どれか 1 つでも動いたら列挙する")
    func enumeratesWhenAnythingMoved() {
        let last = fp()
        #expect(!CandidateEnumerationGate.canSkip(fp(cloud: 8), last: last),
                "クラウドに写真が増えた（一覧の版が進んだ）のに飛ばした")
        #expect(!CandidateEnumerationGate.canSkip(fp(local: 18_205), last: last),
                "端末で写真を撮ったのに飛ばした")
        #expect(!CandidateEnumerationGate.canSkip(fp(scanned: 0), last: last),
                "版を上げて台帳を捨てた（スキャン済みが減った）のに飛ばした")
        #expect(!CandidateEnumerationGate.canSkip(fp(scanned: 86_772), last: last),
                "スキャンが進んだのに飛ばした")
        #expect(!CandidateEnumerationGate.canSkip(fp(unreadable: 0), last: last),
                "候補から外した写真が戻った（忘れた）のに飛ばした")
    }

    /// ⚠️ クラウドの写真が**減った**ときも列挙する（版は増減どちらでも進む）。
    @Test("クラウドの写真が減っても列挙する")
    func enumeratesWhenCloudShrank() {
        #expect(!CandidateEnumerationGate.canSkip(fp(local: 18_000), last: fp()))
    }

    // MARK: - 札を立ててよいか（ADR-253・台帳の宿題）

    /// ⚠️⚠️ **ゲートで本当に危ないのはこちら**。`canSkip` の誤りは「無駄に 11 秒払う」だけだが、
    /// 札を立てる条件の誤りは「**残りが永久にスキャンされない**」になる。
    /// それなのにこの判断は `AnalysisDriver` にインラインで書かれていて、テストが無かった。
    @Test("未スキャンが 0 の回だけ札を立てる")
    func recordsOnlyWhenNothingPending() {
        #expect(CandidateEnumerationGate.shouldRecord(pending: 0))
        #expect(!CandidateEnumerationGate.shouldRecord(pending: 1))
        #expect(!CandidateEnumerationGate.shouldRecord(pending: 57))
    }

    /// ⚠️ **数えられなかった（nil）を「0 件だった」と混ぜない**（ADR-207/242/253）。
    /// 台帳の取得に失敗した回に札が立つと、その端末では顔スキャンが二度と始まらない。
    @Test("数えられなかった回（nil）は札を立てない — 0 と混ぜない")
    func doesNotRecordWhenCountUnavailable() {
        #expect(!CandidateEnumerationGate.shouldRecord(pending: nil))
        #expect(CandidateEnumerationGate.shouldRecord(pending: 0))
    }
}
