import Foundation
import Testing
import PerceptionCore
@testable import FaceCore

/// 人物の構成が変わったときの通知（AI アルバムの掃除・グループアルバムの描き直し）。
///
/// ⚠️ 通知そのものは軽いが、**受け手が顔の台帳を全件引く**。回答 1 回ごとに出すと、
/// 回答自身が待つ `@ModelActor` の列に毎回その全件走査が割り込む（diagnostics-68）。
/// ADR-95・diagnostics-51 が回答の経路から重い処理を外したのと同じ理由で、
/// レビュー表示中はためて、閉じるときに 1 回だけ出す。
@Suite("人物の編集通知", .serialized)
@MainActor
struct PeopleEditNotifyTests {

    private func makeEngine() -> PeopleEngine {
        PeopleEngine(faceProvider: nil, store: FaceStore(isStoredInMemoryOnly: true))
    }

    @Test("レビュー表示中は通知をためて、閉じるときに 1 回だけ出す")
    func notificationsAreBatchedWhileReviewing() {
        let engine = makeEngine()
        let before = engine.editVersion

        engine.beginPeopleReloadHold()
        for _ in 0..<5 { engine.notifyPeopleEdited() }   // 連続回答
        #expect(engine.editVersion == before,
                "回答のたびに通知した（掃除が全件走査を毎回割り込ませる）")

        engine.endPeopleReloadHold()
        #expect(engine.editVersion == before + 1, "閉じたのに通知が出ない（掃除が走らない）")
    }

    @Test("保留していなければその場で通知する")
    func notifiesImmediatelyWhenNotHeld() {
        let engine = makeEngine()
        let before = engine.editVersion
        engine.notifyPeopleEdited()
        #expect(engine.editVersion == before + 1)
    }

    @Test("保留中に何も起きなければ、閉じても通知しない")
    func noNotificationWhenNothingChanged() {
        let engine = makeEngine()
        let before = engine.editVersion
        engine.beginPeopleReloadHold()
        engine.endPeopleReloadHold()
        #expect(engine.editVersion == before, "何もしていないのに掃除を起こした")
    }

    @Test("入れ子の保留は、いちばん外が閉じるまで出さない")
    func nestedHoldsDeferUntilTheOutermostCloses() {
        let engine = makeEngine()
        let before = engine.editVersion
        engine.beginPeopleReloadHold()
        engine.beginPeopleReloadHold()
        engine.notifyPeopleEdited()
        engine.endPeopleReloadHold()
        #expect(engine.editVersion == before, "内側が閉じただけで通知した")
        engine.endPeopleReloadHold()
        #expect(engine.editVersion == before + 1)
    }
}
