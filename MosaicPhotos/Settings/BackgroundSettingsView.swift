import MosaicSupport
import SwiftUI

/// アプリ全体に効く「バックグラウンド処理 × 電源」設定（General 配下）。
/// 特定機能（Albums 等）ではなくアプリ横断のため、設定ルートの General に置く。
struct BackgroundSettingsView: View {
    @AppStorage(PowerStateMonitor.policyKey)
    private var powerPolicyRaw = BackgroundPowerPolicy.whileCharging.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Run background work", selection: $powerPolicyRaw) {
                    Text("While charging").tag(BackgroundPowerPolicy.whileCharging.rawValue)
                    Text("Always").tag(BackgroundPowerPolicy.always.rawValue)
                    Text("Off").tag(BackgroundPowerPolicy.off.rawValue)
                }
            } header: {
                Text("Background Work")
            } footer: {
                Text("Applies across the whole app: AI indexing, automatic albums, place scanning, "
                     + "Dropbox sync and backup. “While charging” runs only when plugged in and Low Power Mode "
                     + "is off — saves battery. “Always” ignores power state; “Off” pauses all background work. "
                     + "Default: While charging.")
            }
        }
        .navigationTitle("Background & Battery")
        .navigationBarTitleDisplayMode(.inline)
    }
}
