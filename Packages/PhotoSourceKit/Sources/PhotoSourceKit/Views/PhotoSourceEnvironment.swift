#if canImport(UIKit)
import SwiftUI

/// Environment key that carries a "go home" action down the view hierarchy.
///
/// Set this on a source content view from the home page so that `PhotoGridView`
/// can display a home button without knowing anything about the outer navigation.
/// The default value is `nil`, meaning no home button is shown.
private enum DismissToHomeKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

/// Environment key that carries an "open settings" action down the view hierarchy.
///
/// Set this alongside `dismissToHome` so that `PhotoGridView` can display a
/// settings gear button without depending on the outer navigation structure.
/// The default value is `nil`, meaning no settings button is shown.
private enum ShowSettingsKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

/// 写真 id（`PhotoItem.id`）から抽出済み情報を取得するプロバイダ。アプリ側が AutoAlbumCore を
/// 背後に注入する。未注入なら表示しない（レイヤー分離：PhotoSourceKit は AutoAlbumCore に依存しない）。
private enum PhotoInsightKey: EnvironmentKey {
    static let defaultValue: (@Sendable (String) async -> PhotoInsight?)? = nil
}

/// ユーザーが写真を能動操作中か（スクラブ等）を上位へ通知するシンク。アプリ側が背景処理
/// （CLIP 埋め込み）の一時停止に使う。未注入なら無視（レイヤー分離）。
/// 写真の利用イベント（フル画面の閲覧・共有・将来の再生）。AutoAlbumCore 非依存を保つため
/// PhotoSourceKit 側の enum で表し、アプリ層（SourceHostView）がエンジンへ橋渡しする。
public enum PhotoUsageEvent: Sendable {
    case view, play, share
}

private enum PhotoUsageEventKey: EnvironmentKey {
    static let defaultValue: (@Sendable (PhotoUsageEvent, String) async -> Void)? = nil
}

extension EnvironmentValues {
    /// 利用イベントの記録クロージャ（`PhotoItem.id` を渡す）。nil なら記録しない。
    public var photoUsageEvent: (@Sendable (PhotoUsageEvent, String) async -> Void)? {
        get { self[PhotoUsageEventKey.self] }
        set { self[PhotoUsageEventKey.self] = newValue }
    }
}

/// グリッド（サムネイル）用の顔ハイライト。`PhotoItem.id` を受け取り、**中央正方形クロップ表示の
/// 単位座標（原点左上）**に変換済みの矩形を返す（変換は注入側＝元画像のアスペクト比を知っている層が行う）。
/// nil（既定）ならグリッドの顔ボタン自体を出さない。
/// 写真一覧画面（グリッド）右上の「…」メニュー。アルバム固有の操作（編集/削除/改名/束ね等）を
/// ナビバー右上に出すための seam（AutoAlbumCore 非依存を保つため呼び出し側が AnyView を渡す）。
/// nil（既定）なら「…」ボタン自体を出さない。ホームカードの「…」/長押しと同じ操作を画面内でも提供。
private enum SourceMenuKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> AnyView)? = nil
}

extension EnvironmentValues {
    public var sourceMenuContent: (@MainActor () -> AnyView)? {
        get { self[SourceMenuKey.self] }
        set { self[SourceMenuKey.self] = newValue }
    }
}

/// 「ベストショット」フィルタのメンバーシップを返すプロバイダ。台帳から判定集合を読み込み、
/// `PhotoItem.id`（文字列化）を受ける同期判定クロージャを返す（集合はクロージャがキャプチャ）。
/// nil（既定）ならフィルタシートに欄自体を出さない（レイヤー分離：判定はアプリ側＝AutoAlbumCore）。
private enum PhotoQualityProviderKey: EnvironmentKey {
    static let defaultValue: (@Sendable () async -> (@Sendable (String) -> Bool))? = nil
}

extension EnvironmentValues {
    public var photoQualityProvider: (@Sendable () async -> (@Sendable (String) -> Bool))? {
        get { self[PhotoQualityProviderKey.self] }
        set { self[PhotoQualityProviderKey.self] = newValue }
    }
}

private enum FaceHighlightGridKey: EnvironmentKey {
    static let defaultValue: (@Sendable (String) async -> [CGRect])? = nil
}

extension EnvironmentValues {
    public var faceHighlightGridProvider: (@Sendable (String) async -> [CGRect])? {
        get { self[FaceHighlightGridKey.self] }
        set { self[FaceHighlightGridKey.self] = newValue }
    }
}

/// 写真ごとの追加操作（人物アルバムの「この写真はこの人ではない」など）。
private enum PhotoContextActionsKey: EnvironmentKey {
    static let defaultValue: [PhotoContextAction] = []
}

private enum FaceHighlightKey: EnvironmentKey {
    static let defaultValue: (@Sendable (String) async -> [CGRect])? = nil
}

private enum PhotoInteractionKey: EnvironmentKey {
    static let defaultValue: ((Bool) -> Void)? = nil
}

public extension EnvironmentValues {
    var dismissToHome: (() -> Void)? {
        get { self[DismissToHomeKey.self] }
        set { self[DismissToHomeKey.self] = newValue }
    }

    var showSettings: (() -> Void)? {
        get { self[ShowSettingsKey.self] }
        set { self[ShowSettingsKey.self] = newValue }
    }

    var photoInsight: (@Sendable (String) async -> PhotoInsight?)? {
        get { self[PhotoInsightKey.self] }
        set { self[PhotoInsightKey.self] = newValue }
    }

    /// 全画面写真で**認識した顔をハイライト**する矩形群（Vision 正規化座標・原点左下）。
    /// 人物アルバム（PersonAlbumView）が「その人物の顔だけ」を返すよう注入する。
    /// nil（既定）ならハイライトなし＝通常の全画面表示。
    var faceHighlightProvider: (@Sendable (String) async -> [CGRect])? {
        get { self[FaceHighlightKey.self] }
        set { self[FaceHighlightKey.self] = newValue }
    }

    /// 写真 1 枚に対する**追加の操作**（人物アルバムの「この写真はこの人ではない」など）。
    ///
    /// ⚠️ `PhotoSourceKit` は顔の仕組みを知らない（`AutoAlbumCore`/`FaceCore` に依存しない）。
    /// 呼び出し側（人物アルバム）が「表示名と実行」を渡し、こちらは**グリッドの長押し**と
    /// **全画面のメニュー**に並べるだけ——`faceHighlightProvider` と同じ形の seam。
    /// nil（既定）なら操作は出ない。
    var photoContextActions: [PhotoContextAction] {
        get { self[PhotoContextActionsKey.self] }
        set { self[PhotoContextActionsKey.self] = newValue }
    }

    var photoInteraction: ((Bool) -> Void)? {
        get { self[PhotoInteractionKey.self] }
        set { self[PhotoInteractionKey.self] = newValue }
    }
}
#endif
