#if canImport(UIKit)
import UIKit
#endif
import Foundation
import Observation

/// バックグラウンド処理の電源ポリシー。`UserDefaults`（`PowerStateMonitor.policyKey`）に Int で保存。
public enum BackgroundPowerPolicy: Int, Sendable, CaseIterable {
    /// 充電中（かつ低電力モード OFF）のときだけ背景処理を実行する。既定。
    case whileCharging = 0
    /// 電源状態に関係なく常に実行（従来動作）。
    case always = 1
    /// 背景処理を一切行わない。
    case off = 2
}

/// 端末の電源状態（充電中か／低電力モードか）を監視し、設定ポリシーと合わせて
/// 「いまバックグラウンド処理を走らせてよいか」を判定する横断モニタ。
///
/// `MemoryPressureMonitor` と同系列の共有モニタ。各バックグラウンド処理（CLIP 背景埋め込み・
/// 自動アルバム生成・場所スキャン・Dropbox 同期・バックアップ）が `backgroundAllowed()` を見て
/// 実行/一時停止を判断する。電源・低電力の変化は通知で取り込み、`@Observable` で UI も追従できる。
@MainActor
@Observable
public final class PowerStateMonitor {
    public static let shared = PowerStateMonitor()

    /// 背景処理ポリシーの永続キー（設定 UI と共有）。
    public static let policyKey = "background.powerPolicy"

    /// 電源に接続中か（charging / full）。UIKit 非対応環境（macOS テスト）では true 扱い。
    public private(set) var isOnPower: Bool = true
    /// 低電力モードか。
    public private(set) var isLowPowerMode: Bool = false
    /// バッテリー残量（0...1）。取得不可（macOS テスト・監視無効）は 1.0 扱い＝残量でブロックしない。
    public private(set) var batteryLevel: Float = 1.0

    private init() {
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshBattery()
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshBattery() }
        }
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshBattery() }
        }
        #endif
    }

    #if canImport(UIKit)
    private func refreshBattery() {
        // 「電池駆動と確定したとき（.unplugged）以外は電源扱い」にする。
        // シミュレータや判定不能時は `.unknown` を返すため、charging/full のみで判定すると
        // 充電中でないとみなされ背景処理が全部ゲートで止まる。`.unknown` は電源扱いにして
        // ロックしない（実機は .charging/.full/.unplugged を正しく返す）。
        isOnPower = (UIDevice.current.batteryState != .unplugged)
        let level = UIDevice.current.batteryLevel
        batteryLevel = level >= 0 ? level : 1.0   // -1（不明）は残量でブロックしない
    }
    #endif

    /// 現在のポリシー（未設定は既定の「充電中のみ」）。
    public var policy: BackgroundPowerPolicy {
        BackgroundPowerPolicy(rawValue: UserDefaults.standard.integer(forKey: Self.policyKey)) ?? .whileCharging
    }

    /// いまバックグラウンド処理を走らせてよいか（ポリシー × 電源状態）。
    /// `whileCharging` は「電源接続中 かつ 低電力モード OFF」。
    public func backgroundAllowed() -> Bool {
        switch policy {
        case .off:           return false
        case .always:        return true
        case .whileCharging: return isOnPower && !isLowPowerMode
        }
    }
}
