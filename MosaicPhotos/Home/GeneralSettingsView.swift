import SwiftUI

/// 「General」：アプリ情報（バージョン）。詳細なビルド情報・ログ・キャッシュ消去は
/// Developer Options / Storage 画面へ移設した。
struct GeneralSettingsView: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"

    var body: some View {
        Section("About") {
            LabeledContent("Version", value: version)
        }
    }
}
