/// `needsSetup` プレースホルダに出す解決アクション（任意）。タイトルはローカライズ済み文字列。
public enum SetupAction: Equatable, Sendable {
    /// iOS の「設定」アプリを開く（写真権限など OS 側の許可が必要なとき）。
    case openSystemSettings
    /// アプリ内の「設定」シートを開く（Dropbox 接続など、アプリ内で直せるとき）。
    case openAppSettings
}

/// Unified loading / permission state shared across photo sources.
public enum PhotoLoadState: Equatable {
    /// Not yet started. Triggers `start()` on first appearance.
    case idle
    /// Cannot load — permission denied or not connected.
    /// `systemImage` is the SF Symbol shown in the placeholder.
    /// `action` があれば解決ボタン（設定を開く等）を出す。
    case needsSetup(message: String, detail: String?, systemImage: String, action: SetupAction?)
    /// Loading in progress.
    case loading
    /// Items loaded and available.
    case loaded
    /// Load succeeded but returned zero items.
    case empty
    /// Load failed with an error message.
    case failed(String)
}
