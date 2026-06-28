import MosaicSupport
import SwiftUI

/// アプリ全体に効く「バックグラウンド処理 × 電源」設定（General 配下）。
/// 特定機能（Albums 等）ではなくアプリ横断のため、設定ルートの General に置く。
struct BackgroundSettingsView: View {
    @AppStorage(PowerStateMonitor.policyKey)
    private var powerPolicyRaw = BackgroundPowerPolicy.whileCharging.rawValue
    @AppStorage(NetworkStateMonitor.policyKey)
    private var dataPolicyRaw = BackgroundDataPolicy.wifiOnly.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Power", selection: $powerPolicyRaw) {
                    Text("While charging").tag(BackgroundPowerPolicy.whileCharging.rawValue)
                    Text("Always").tag(BackgroundPowerPolicy.always.rawValue)
                    Text("Off").tag(BackgroundPowerPolicy.off.rawValue)
                }
            } header: {
                Text("Background Work")
            } footer: {
                Text(L("Applies across the whole app: AI indexing, automatic albums, place scanning, Dropbox sync and backup. “While charging” runs only when plugged in and Low Power Mode is off — saves battery. “Always” ignores power state; “Off” pauses all background work. Default: While charging."))
            }

            Section {
                Picker("Network", selection: $dataPolicyRaw) {
                    Text("Cellular allowed").tag(BackgroundDataPolicy.unrestricted.rawValue)
                    Text("Wi-Fi only").tag(BackgroundDataPolicy.wifiOnly.rawValue)
                    Text("Wi-Fi, skip Low Data").tag(BackgroundDataPolicy.wifiNoLowData.rawValue)
                    Text("Off").tag(BackgroundDataPolicy.off.rawValue)
                }
            } header: {
                Text("Background Data")
            } footer: {
                Text(L("Limits background network use (Dropbox sync, backup uploads, cloud photo indexing, reverse geocoding). “Wi-Fi only” avoids cellular data; “Wi-Fi, skip Low Data” also pauses when Low Data Mode is on. Photos you open or browse are always fetched — only automatic background traffic is limited. Default: Wi-Fi only."))
            }
        }
        .navigationTitle("Background & Battery")
        .navigationBarTitleDisplayMode(.inline)
    }
}
