#if canImport(UIKit)
import AutoAlbumCore
import SwiftUI

/// ピープル関連の画面を開いている間、**顔スキャンに譲らせる**モディファイア（ADR-142）。
///
/// ⚠️ 顔スキャン（`FaceTagger`）と、人物一覧・レビュー候補・診断の問い合わせは
/// **同じ `@ModelActor` を奪い合う**。実機ログ（diagnostics-68）では、スキャン中の
/// 人物一覧の読み込みが通常 0.4 秒のところ **13.3 秒**まで伸びていた。
/// ユーザーが見ている画面が先——スキャンは差分ベースなので、閉じれば続きから再開する。
///
/// 実体は人物一覧の再発行保留（ADR-95）と同じカウンタで、`isBrowsingPeople` が
/// 顔スキャンの `shouldPause` に効く。
public struct PeopleScreenHoldModifier: ViewModifier {
    let peopleEngine: PeopleEngine

    init(peopleEngine: PeopleEngine) { self.peopleEngine = peopleEngine }

    public func body(content: Content) -> some View {
        content
            .onAppear { peopleEngine.beginPeopleReloadHold() }
            .onDisappear { peopleEngine.endPeopleReloadHold() }
    }
}

extension View {
    /// この画面を開いている間、顔スキャンを止めて `@ModelActor` を空ける。
    public func pausesFaceScan(_ peopleEngine: PeopleEngine) -> some View {
        modifier(PeopleScreenHoldModifier(peopleEngine: peopleEngine))
    }
}
#endif
