import Foundation
import MosaicSupport

// MARK: - 取り消し（ADR-136）
//
// 「直前の 1 手を戻す」の窓口。実体（状態の控えと書き戻し）は `FaceStore+Undo.swift` にあり、
// ここは **UI へ見せる説明（`undoLabel`）の同期**と、人物一覧の描き直しだけを持つ。
//
// ⚠️ 分けた理由: `PeopleEngine` は 780 行あり、一覧・スキャン・編集・取り消し・調査が同居して
// いた。取り消しは「どの操作の後に控えを捨てるか」を横断的に決める関心なので、独立させると
// 追いやすい（振る舞いは変えていない＝純粋な分割）。

extension PeopleEngine {


    /// 直前の判定の説明（nil＝戻せるものが無い）。レビュー画面の「戻す」に出す。
    ///
    /// ⚠️ 実フィードバック: 「ピープルの確認をしていると、たまに、間違った！と思うことがある」。
    /// 確認は連続で答える画面なので、**間違いに気づくのは次のカードが出た直後**。
    /// そこで戻せないと、あとから顔の管理を開いて手で直すことになる。
    /// 直前の判定を取り消す。戻した内容の説明を返す（何も無ければ nil）。
    @discardableResult
    public func undoLastAnswer() async -> String? {
        Diagnostics.breadcrumb("people.undo")
        let undone = await store.undoLast()
        await refreshUndoLabel()
        await loadPeople()
        return undone
    }

    /// 控えの状態を UI に反映する。
    func refreshUndoLabel() async {
        undoLabel = await store.lastUndoLabel()
    }

    /// 取り消しの控えを捨てる（再クラスタ・再スキャンの後は戻す先が変わっている）。
    func clearUndoHistory() async {
        await store.clearUndo()
        undoLabel = nil
    }
}
