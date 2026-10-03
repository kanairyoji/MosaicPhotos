import Foundation

/// **顔とタグ/埋め込みを同じ枠で同時に起こさない**（ADR-237・純ロジック・テスト対象）。
///
/// ## なぜ要るか
/// `runPrologue` は「タグ/埋め込みを起こす → 顔スキャンを起こす」を続けて行っていた。
/// どちらも背景トリクルで、ANE ゲート（`MLInferenceGate`）が**推論**は直列化するので
/// 動作は正しい。⚠️ しかし**モデルは両方載ったまま**になる——CLIP の画像塔と顔モデルと
/// Vision が同時に常駐し、実機ログ diagnostics-97 では
///
/// ```
/// 00:33:00  575MB  bgfill: plan tags(40)→embed
/// 00:33:07  728MB
/// 00:33:11  763MB  faces: startScan（candidates=86552）
/// 00:33:14  823MB  faces: start（todo=57）
/// ```
///
/// と **14 秒で +248MB**、最大 823MB まで上がっていた（前の実機ログでは 617MB まで下げていた）。
/// ⚠️ ANE ゲートは「同時に 1 つ**推論**しない」ための仕掛けで、「同時に 1 つ**載せる**」は
/// 誰も見ていなかった。ADR-223/226/228 は「使い終わったら手放す」側で、
/// **使い始めを重ねない**側が抜けていた。
///
/// ## 決まり
/// 1 つの枠では**どちらか片方だけ**を起こす。両方に残作業があるときは**前回と違う方**にして、
/// どちらも飢えないようにする。⚠️ 交互にしないと、顔に常に残作業がある状況
/// （新しい写真が毎日入る）でタグ/埋め込みが永久に走らない。
enum AnalysisTurn {

    /// この枠で起こすもの。
    enum Choice: String, Equatable, Sendable {
        /// 顔スキャン（顔モデル＋Vision）。
        case faces
        /// タグ → 埋め込み（Vision シーンタグ＋CLIP 画像塔）。
        case tags
        /// どちらも残作業が無い。
        case none
    }

    /// - Parameters:
    ///   - facesRunning: 顔スキャンが**もう走っている**か。
    ///   - tagsRunning: タグ/埋め込みが**もう走っている**か。
    ///   - faceScanPossible: 顔スキャンがこの端末で走り得るか（モデルが同梱されているか）。
    ///     ⚠️⚠️ **残作業の数を入れてはいけない**。`faceBacklog` は一度測ったら
    ///     スキャン側しか更新しないので、0 になったあと新しい写真が入っても 0 のまま
    ///     ——それを「仕事が無い」と読むと**顔スキャンが永久に走らなくなる**
    ///     （実装中に一度そう書いて気づいた）。仕事の有無は起こされた側が判断する。
    ///   - lastChoice: 前回この枠で起こしたもの（起動を跨がなくてよい）。
    static func next(facesRunning: Bool, tagsRunning: Bool,
                    faceScanPossible: Bool, lastChoice: Choice) -> Choice {
        // ⚠️ **片方が走っているなら、もう片方は起こさない**（モデルを同時に載せない）。
        // 残作業の数は見ない——数えるには DB を引く必要があり、アイドルの契機は 5 秒ごとに
        // 来るので毎回引くわけにはいかない。「走っているか」は無料で分かる。
        if tagsRunning || facesRunning { return .none }
        // どちらも止まっている。顔が走り得ないならタグ/埋め込み。
        guard faceScanPossible else { return .tags }
        // 両方あり得る → **前回と違う方**（交互にしないと、顔に常に残作業がある状況
        // ——新しい写真が毎日入る——でタグ/埋め込みが永久に走らない）。
        return lastChoice == .faces ? .tags : .faces
    }

    /// **滞留している実行を明け渡させる**契機か（ADR-95 / diagnostics-38・純ロジック）。
    ///
    /// ⚠️⚠️ **順番の外に置く**（レビューで見つけた・2026-09-29）。ADR-237 で「順番が `.tags` の
    /// ときだけ `restartBackgroundFill()` を呼ぶ」と書いたが、`next` は**タグが走っていれば
    /// `.none` を返す**ので、「走っているように見えて眠っている実行を明け渡させる」という
    /// 窓の逃げ道が**まさにその状況で消えていた**——
    /// 前面で始まった実行が `waitWhilePaused`（最大 60 秒）で止まったまま `isTagging` を握り、
    /// 夜間の枠（約 77 秒）が丸ごと空転する。diagnostics-38 で踏んだ形そのものに戻る。
    ///
    /// ⚠️ ADR-237（モデルを同時に載せない）とは矛盾しない——**明け渡しは置き換え**であって、
    /// 2 つ目のモデルを載せるわけではない。顔はこの回も起こさない。
    /// - Parameters:
    ///   - isPrivilegedTrigger: 夜間の処理枠、またはブーストの終了か。
    ///   - turn: `next(...)` が返した順番。
    ///   - tagsRunning: タグ/埋め込みが実行中フラグを握っているか。
    static func preemptsStalledTags(isPrivilegedTrigger: Bool, turn: Choice,
                                    tagsRunning: Bool) -> Bool {
        isPrivilegedTrigger && turn != .tags && tagsRunning
    }
}

/// **候補を列挙する前に「変わり得たか」を見る**（ADR-247・純ロジック・実機ログ diagnostics-102）。
///
/// ⚠️⚠️ 候補の列挙（`analysisCandidates`）は 8.6 万件で**約 11 秒**、12 万件の refKey と
/// クラウド 10.8 万行を一時的に積む。ところが解析が終わった端末では、その 11 秒は毎回
/// **「やることは無い」と知るためだけ**に払われていた（実機 102 では 11 回ぶん）。
///
/// ⚠️ ADR-243 でこれを「次の一手」として残したときの懸念は
/// 「半端にやると**変わったのに気づかない**側の不具合になる」だった。だから指紋は
/// **候補の母集合が動いたら必ず動く**ものだけで作る:
/// 1. クラウドの一覧の版（増減・内容変化で進む）
/// 2. 端末写真（スクショ以外の画像）の枚数
/// 3. スキャン済みの件数（版を上げて台帳を捨てれば減る／進めば増える）
/// 4. 候補から外した件数（ADR-243 の「取れない写真」が増えたら減る）
///
/// ⚠️⚠️ **`faceBacklog` は入れない**（ADR-237 で一度書いて気づいた罠）。あれはスキャン側しか
/// 更新しないので 0 に張り付き、新しい写真が入っても 0 のまま——「仕事が無い」と読むと
/// **顔スキャンが永久に走らなくなる**。
enum CandidateEnumerationGate {

    /// 指紋（4 つの数）。
    struct Fingerprint: Equatable, Codable, Sendable {
        var cloudRevision: Int
        var localCount: Int
        var scanned: Int
        var unreadable: Int
    }

    /// 前回「やることが無い」と分かったときと**全部同じ**なら、列挙ごと飛ばしてよい。
    /// - Parameter last: 前回そう分かったときの指紋（nil＝未記録＝必ず走る）。
    static func canSkip(_ now: Fingerprint, last: Fingerprint?) -> Bool {
        // ⚠️ 未記録なら必ず走る（nil を「同じ」と読むと初回から飛ばしてしまう）。
        guard let last else { return false }
        return now == last
    }

    /// **札を立ててよいか**（＝「やることが無かった」と覚えてよいか）。
    ///
    /// ⚠️⚠️ ゲートで本当に危ないのはこちら側。`canSkip` を間違えれば「無駄に 11 秒払う」だけだが、
    /// **札を立てる条件を間違えると、残りが永久に処理されない**（次からずっと飛ばす）。
    /// それなのにこの判断は呼び出し側にインラインで書かれていて、テストが無かった
    /// ——台帳（gates.md）の宿題に挙がっていた分（ADR-253）。
    /// - Parameter pending: 候補のうち**まだスキャンしていない**枚数。
    ///   **nil＝数えられなかった**（「0 件だった」と混ぜない。ADR-207/242）。
    static func shouldRecord(pending: Int?) -> Bool { pending == 0 }
}
