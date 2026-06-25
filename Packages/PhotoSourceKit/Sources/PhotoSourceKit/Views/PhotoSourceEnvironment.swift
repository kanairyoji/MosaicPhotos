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

    var photoInteraction: ((Bool) -> Void)? {
        get { self[PhotoInteractionKey.self] }
        set { self[PhotoInteractionKey.self] = newValue }
    }
}
#endif
