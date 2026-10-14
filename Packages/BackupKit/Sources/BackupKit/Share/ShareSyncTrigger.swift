import Foundation
import MosaicSupport

/// 共有の反映を「誰が起こしたか」と、起こし方ごとの決まり（1 つの表）。
///
/// 以前は反映を起こす場所が 4 つあり（起動・バックアップ後・夜間の手・手動）、回線の確認・
/// セットの有無・作成元への追従を**呼ぶ側がそれぞれ書いていた**。diagnostics-109 の
/// 「毎窓 2 回走る」はこの形から出た（バックアップ後の 1 回が、夜間の手の 1 回と別に判断していた）。
/// 呼ぶ側は `ShareSyncEngine.sync(_:)` に起こし方を渡すだけにする（ADR-196）。
public enum ShareSyncTrigger: String, CaseIterable, Sendable {
    /// 起動から少し後（保留分・自己修復）。
    case launch
    /// バックアップが終わったとき（待っていた共有写真を反映する）。
    case afterBackup
    /// 夜間の処理枠の手（`shareSync`）。
    case nightly
    /// 共有ハブの「今すぐ反映」。
    case manual
    /// セットの作成・メンバーの変更の直後（エンジンの中から起こす）。
    case edited

    /// 起こし方ごとの決まり。
    public struct Rule: Equatable, Sendable {
        /// 回線ポリシー（Wi-Fi のみ等）に従う。自動で起こすものだけ（手動・夜間の手は呼ぶ側の判断）。
        public let respectsNetworkPolicy: Bool
        /// セットが 1 つも無ければ起こさない（共有ルートの一覧の 1 往復を省く）。
        public let requiresAnySet: Bool
        /// 反映の前に、作成元（人物・AI アルバム）のいまのメンバーへ追従させる（ADR-183 C）。
        public let followsSource: Bool
        /// 待っていた共有写真が無ければ起こさない（`ShareAfterBackupGate`）。
        public let requiresWaitingBackup: Bool
    }

    /// ⚠️ 夜間の手と手動は**同じ決まり**（「押せば夜間と同じことが今すぐ起きる」）。
    public var rule: Rule {
        switch self {
        case .launch:
            Rule(respectsNetworkPolicy: true, requiresAnySet: true,
                 followsSource: false, requiresWaitingBackup: false)
        case .afterBackup:
            Rule(respectsNetworkPolicy: true, requiresAnySet: true,
                 followsSource: false, requiresWaitingBackup: true)
        case .nightly, .manual:
            Rule(respectsNetworkPolicy: false, requiresAnySet: false,
                 followsSource: true, requiresWaitingBackup: false)
        case .edited:
            Rule(respectsNetworkPolicy: false, requiresAnySet: false,
                 followsSource: false, requiresWaitingBackup: false)
        }
    }
}

extension ShareSyncEngine {

    /// 反映を起こす**唯一の入口**。決まりは `ShareSyncTrigger.rule`。
    /// 実際の反映（設定の確認・排他・1 回ぶんの差分）は `syncNow()`。
    public func sync(_ trigger: ShareSyncTrigger) async {
        let rule = trigger.rule
        if rule.respectsNetworkPolicy, !networkAllowed() { return }
        if rule.requiresAnySet, !(await hasAnySet()) { return }
        if rule.followsSource { await refreshAllFromSource() }
        if rule.requiresWaitingBackup {
            guard ShareSettingsKeys.isProvideEnabled(defaults) else { return }
            let waiting = await storeProvider().shareWaitingBackupCounts()
            guard ShareAfterBackupGate.shouldSync(waitingBackup: waiting) else {
                // ⚠️ 効いた回数が見えるログ（ADR-250）。無いと「一度も効かない」に気づけない。
                Diagnostics.mark("share sync: バックアップ後の反映を見送る（待っている共有写真が無い・"
                                 + "\(waiting?.count ?? 0) セット）")
                return
            }
        }
        await syncNow()
    }
}
