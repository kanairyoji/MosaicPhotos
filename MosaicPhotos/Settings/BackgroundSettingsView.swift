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
                // ⚠️ 「熱くなったら停止」という表示をやめた（実フィードバック）。止めているのは
                // 温度のためではなく**充電のため**で、名前が実態と食い違うと「満充電でも止まるのは
                // なぜ？」という当然の疑問に答えられない。何を優先しているかをそのまま名前にする。
                Toggle("Prioritize charging over background work", isOn: $pauseWhenHot)
            } footer: {
                Text(L("When the device gets hot, iOS pauses charging — so overnight processing can leave you with a phone that is hot and not charged, and the next night makes no progress either. With this on, background analysis stands down while the device is hot and resumes once it has cooled. Once the battery is charged (98% or more) there is nothing left to protect, so processing continues even when the device is warm. Default: On."))
            }
        }
        .navigationTitle("Background & Battery")
        .navigationBarTitleDisplayMode(.inline)
    }
}
