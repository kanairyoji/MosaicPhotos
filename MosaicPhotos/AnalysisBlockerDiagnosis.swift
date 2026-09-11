import Foundation

/// **「いま自動の解析が進まない理由」**の判定（純ロジック・diagnostics-81）。
///
/// 夜間の解析は OS が処理枠（BGProcessingTask）をくれたときに進む。枠が来るかは OS の裁量だが、
/// **来ない理由の多くは端末側の設定**で、利用者はそれを知る手段が無かった（Mac に繋いで
/// Console で `dasd` を読むしかない）。実フィードバック「電源も繋いでアプリも開いているのに
/// 何も進まない」に対して、アプリ自身が言えることは全部言う。
enum AnalysisBlockerDiagnosis {

    /// 自動の解析が動かない理由（表示順＝直しやすい順）。
    enum Blocker: Equatable {
        /// 「自動で解析する」が OFF（アプリの設定）。
        case automaticOff
        /// iOS の「App のバックグラウンド更新」が OFF／制限。処理枠そのものが来ない。
        case backgroundRefreshOff
        /// 低電力モード（どの設定でも重い処理は止まる）。
        case lowPowerMode
        /// 電源ポリシーが「充電中のみ」なのに充電していない。
        case notCharging
        /// 発熱で停止中（充電を優先する・ADR-118）。
        case tooHot
        /// 回線ポリシーを満たしていない（クラウド写真の解析だけが止まる）。
        case networkBlocked
    }

    /// - Parameters:
    ///   - automaticEnabled: 「自動で解析する」（`HeavyWorkTiming` が paused でない）。
    ///   - backgroundRefreshAvailable: iOS の App バックグラウンド更新が使えるか。
    ///   - lowPowerMode: 低電力モード。
    ///   - requiresPower: 電源ポリシーが「充電中のみ」か。
    ///   - onPower: 電源に接続されているか。
    ///   - thermalPaused: 発熱で停止中か。
    ///   - networkAllowed: 回線ポリシーを満たしているか。
    static func blockers(automaticEnabled: Bool,
                         backgroundRefreshAvailable: Bool,
                         lowPowerMode: Bool,
                         requiresPower: Bool,
                         onPower: Bool,
                         thermalPaused: Bool,
                         networkAllowed: Bool) -> [Blocker] {
        var out: [Blocker] = []
        if !automaticEnabled { out.append(.automaticOff) }
        if !backgroundRefreshAvailable { out.append(.backgroundRefreshOff) }
        if lowPowerMode { out.append(.lowPowerMode) }
        if requiresPower && !onPower { out.append(.notCharging) }
        if thermalPaused { out.append(.tooHot) }
        if !networkAllowed { out.append(.networkBlocked) }
        return out
    }

    /// 「条件は満たしているのに長く枠が来ていない」か。
    ///
    /// Apple は「予約から起動まで何時間もかかり得る」と明記しているので、短い空白は正常。
    /// ただし**半日以上**空くのは、アプリを強制終了した・端末が jetsam でアプリを落とした等の
    /// 兆候なので、利用者に「今すぐ解析」を勧める（実機 diagnostics-81 では 12 時間空いた）。
    static let starvationThresholdMinutes = 12 * 60

    static func isWindowStarved(blockers: [Blocker], minutesSinceLastWindow: Int?) -> Bool {
        guard blockers.isEmpty, let minutes = minutesSinceLastWindow else { return false }
        return minutes >= starvationThresholdMinutes
    }
}
