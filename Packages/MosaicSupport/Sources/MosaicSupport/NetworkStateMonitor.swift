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
    /// ⚠️ nonisolated: 不変の `let` で、MainActor 外（設定移行の純ロジック等）からも読むため。
    public nonisolated static let policyKey = "background.dataPolicy"

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

    /// いま**投機的な先読み**（クラウドサムネ/フル画像の prefetch）を行ってよいか（ADR-81）。
    ///
    /// 先読みは「まだ見ていない写真」を推測で落とすので、**ユーザーが今見ている画像の取得とは
    /// 性質が違う**。`BackgroundDataPolicy.off` の定義（「閲覧時の手動取得のみ」）どおり、
    /// 自動通信として回線ポリシーの対象にする。加えて**低電力モード中は行わない**
    /// （iOS の慣習＝明示的な省電力要求のときは投機的な処理を止める）。
    ///
    /// ⚠️ 電源ポリシー（充電中のみ）は**課さない**。先読みはユーザーがスクロールしている
    /// 最中にだけ起きる前景動作で、これを電源条件で止めると「バッテリー駆動では常にサムネが
    /// 出遅れる」＝通常利用が壊れる。電源ポリシーが守るのは背面での消耗であり、画面を見ている
    /// 間の消費はディスプレイが支配的なため、ここで絞る利得が小さい。
    public func speculativeFetchAllowed() -> Bool {
        networkAllowed() && !PowerStateMonitor.shared.isLowPowerMode
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
