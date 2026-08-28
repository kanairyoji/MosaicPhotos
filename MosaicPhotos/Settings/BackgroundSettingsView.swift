import MosaicSupport
import SwiftUI

/// アプリ全体に効く「バックグラウンド処理 × 電源」設定（General 配下）。
/// 特定機能（Albums 等）ではなくアプリ横断のため、設定ルートの General に置く。
struct BackgroundSettingsView: View {
    @AppStorage(PowerStateMonitor.policyKey)
    private var powerPolicyRaw = BackgroundPowerPolicy.whileCharging.rawValue
    @AppStorage(NetworkStateMonitor.policyKey)
    private var dataPolicyRaw = BackgroundDataPolicy.wifiOnly.rawValue
    /// 発熱したら重い処理を止める（既定 ON）。⚠️ 既定を ON にする理由は
    /// 「速さ」ではなく「充電が終わること」——発熱で充電が止まると翌晩も処理が進まない。
    /// ⚠️ `ThermalGate` と**同じキー・同じ UserDefaults** を見るので橋渡しは書かない
    /// （書くと同じ値を二重に保存するだけで、出典が 2 つあるように見えてしまう）。
    @AppStorage(ThermalGate.policyKey) private var pauseWhenHot = true

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
            Section {
                Toggle("Pause when the device gets hot", isOn: $pauseWhenHot)
            } footer: {
                Text(L("Stops background analysis while the device is hot, and resumes once it has cooled down. Without this, overnight processing can keep the device warm enough that iOS pauses charging — so you wake up to a phone that is hot and not charged, and the next night makes no progress either. Default: On."))
            }
        }
        .navigationTitle("Background & Battery")
        .navigationBarTitleDisplayMode(.inline)
    }
}
