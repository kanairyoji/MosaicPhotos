import Foundation
import Network
import Observation

/// 背景処理の**通信**ポリシー。`UserDefaults`（`NetworkStateMonitor.policyKey`）に Int で保存。
/// 既定は Wi-Fi のみ（rawValue 0）。
public enum BackgroundDataPolicy: Int, Sendable, CaseIterable {
    /// Wi-Fi / 有線のときだけ背景通信を行う。既定。
    case wifiOnly = 0
    /// セルラーでも背景通信を行う。
    case unrestricted = 1
    /// Wi-Fi / 有線 かつ 低データモードでないとき。
    case wifiNoLowData = 2
    /// 背景通信を一切行わない（閲覧時の手動取得のみ）。
    case off = 3
}

/// 回線種別（Wi-Fi / セルラー / 低データモード等）を監視し、設定ポリシーと合わせて
/// 「いま**背景の通信**を行ってよいか」を判定する横断モニタ。`PowerStateMonitor` と同系列。
///
/// Dropbox 同期・バックアップ・クラウド写真の CLIP 埋め込み（サムネDL）・逆ジオコーディング等、
/// **自動/継続のバックグラウンド通信**が `networkAllowed()` を見て実行/保留を判断する。
/// ユーザーが閲覧中に行う取得（サムネ/フル画像）は前景操作なので**ゲート対象外**。
@MainActor
@Observable
public final class NetworkStateMonitor {
    public static let shared = NetworkStateMonitor()

    /// 背景通信ポリシーの永続キー（設定 UI と共有）。
    public static let policyKey = "background.dataPolicy"

    /// 到達可能（オンライン）か。
    public private(set) var isReachable = false
    /// Wi-Fi もしくは有線か。
    public private(set) var isOnWiFi = false
    /// 従量課金（セルラー・テザリング等）か。
    public private(set) var isExpensive = false
    /// 低データモードか。
    public private(set) var isConstrained = false

    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor in
                self?.apply(reachable: reachable, wifi: wifi, expensive: expensive, constrained: constrained)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.mosaicphotos.NetworkStateMonitor"))
    }

    private func apply(reachable: Bool, wifi: Bool, expensive: Bool, constrained: Bool) {
        isReachable = reachable
        isOnWiFi = wifi
        isExpensive = expensive
        isConstrained = constrained
    }

    /// 現在のポリシー（未設定は既定の「Wi-Fi のみ」）。
    public var policy: BackgroundDataPolicy {
        BackgroundDataPolicy(rawValue: UserDefaults.standard.integer(forKey: Self.policyKey)) ?? .wifiOnly
    }

    /// いま背景の通信を行ってよいか（ポリシー × 回線状態）。
    public func networkAllowed() -> Bool {
        switch policy {
        case .off:           return false
        case .unrestricted:  return isReachable
        case .wifiOnly:      return isReachable && isOnWiFi && !isExpensive
        case .wifiNoLowData: return isReachable && isOnWiFi && !isExpensive && !isConstrained
        }
    }
}
