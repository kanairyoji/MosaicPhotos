import Foundation
import MosaicSupport

/// **オフロードの緊急停止**（ADR-202）。
///
/// オフロードは端末の原本を消すので、クラウドのコピーが**唯一のコピー**になる。
/// そのコピーが Dropbox 側で消された／差し替えられたことに照合（reconcile）が気づいたら、
/// それは「利用者が知らないうちに写真を失っている」状態であり、**同じことを繰り返させない**のが先決。
///
/// - 自動オフロードを**その場で「オフロードしない」へ戻す**（設定を強制変更する）
/// - 写真の一覧の上に知らせを出す（`sourceNotice`）
/// - 利用者が設定画面で**「確認した」を押すまで**、自動オフロードを設定できない
///
/// ⚠️ 勝手に設定を変えるのは本来避けるべきだが、ここは**写真が失われ続ける**経路なので
/// 「止めてから知らせる」を選ぶ。止めた事実と理由は必ず画面に出す（黙って変えない）。
public enum OffloadHalt {

    // MARK: - 永続キー

    static let haltedAtKey = "offload.halt.at"
    static let missingCountKey = "offload.halt.missingCount"
    static let samplePathsKey = "offload.halt.samplePaths"
    static let acknowledgedKey = "offload.halt.acknowledged"

    /// 画面に出す見本の件数（多すぎても読めない）。
    static let sampleLimit = 5

    // MARK: - 状態

    /// 止めた事実の内容（画面表示用・値型）。
    public struct Notice: Equatable, Sendable {
        public let haltedAt: Date
        public let missingCount: Int
        /// 実体が見つからなかった写真のパス（先頭 `sampleLimit` 件）。
        public let samplePaths: [String]
    }

    /// **未確認の停止**があるか（＝知らせを出し、自動オフロードを触らせない）。
    public static var isHalted: Bool { current != nil }

    /// 未確認の停止の内容（無ければ nil）。
    public static var current: Notice? {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: acknowledgedKey),
              let at = defaults.object(forKey: haltedAtKey) as? Date else { return nil }
        return Notice(haltedAt: at,
                      missingCount: defaults.integer(forKey: missingCountKey),
                      samplePaths: defaults.stringArray(forKey: samplePathsKey) ?? [])
    }

    // MARK: - 記録と解除

    /// 実体が見つからないオフロード済み写真を見つけたときに呼ぶ。
    ///
    /// ⚠️ **自動オフロードを 0（オフロードしない）へ落とすのはここだけ**。設定画面側は
    /// 「確認した」までピッカーを触らせないだけで、値は書き換えない（二重に書くと、
    /// どちらが止めたのか分からなくなる）。
    /// - Returns: 新しく止めたか（既に未確認の停止があるときは件数だけ更新して false）。
    @discardableResult
    public static func record(missingPaths: [String], at date: Date = Date()) -> Bool {
        guard !missingPaths.isEmpty else { return false }
        let defaults = UserDefaults.standard
        let wasHalted = isHalted
        defaults.set(missingPaths.count, forKey: missingCountKey)
        defaults.set(Array(missingPaths.prefix(sampleLimit)), forKey: samplePathsKey)
        if !wasHalted {
            defaults.set(date, forKey: haltedAtKey)
            defaults.set(false, forKey: acknowledgedKey)
        }
        // 自動オフロードを止める（設定の強制変更）。
        defaults.set(0, forKey: BackupSettingsKeys.offloadAutoThresholdMB)
        Diagnostics.mark("offload: HALTED — \(missingPaths.count) offloaded photo(s) missing in Dropbox")
        BackupLogger.error("Offload halted: \(missingPaths.count) offloaded photo(s) are gone from Dropbox")
        return !wasHalted
    }

    /// 利用者が「確認した」を押した。以後は知らせを出さず、自動オフロードも設定できる。
    /// ⚠️ 自動オフロードを**勝手に戻さない**（止めたままにして、利用者に選ばせる）。
    public static func acknowledge() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: haltedAtKey) != nil else { return }
        defaults.set(true, forKey: acknowledgedKey)
        Diagnostics.mark("offload: halt acknowledged by the user")
    }

    /// テスト・Debug 用の消去（記録そのものを無かったことにする）。
    public static func resetForTesting() {
        let defaults = UserDefaults.standard
        for key in [haltedAtKey, missingCountKey, samplePathsKey, acknowledgedKey] {
            defaults.removeObject(forKey: key)
        }
    }
}
