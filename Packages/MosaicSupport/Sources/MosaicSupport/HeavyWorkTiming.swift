import Foundation

/// 重い処理（AI 索引・顔認識・アルバム生成）を**いつ動かすか**の判定（ADR-80）。
///
/// ## 3 つの軸を独立させる（ADR-80 → ADR-195）
/// 旧実装は 5 段階の梯子（paused / nightly / chargeActive / battery / unlimited）で、
/// 「前面でも動かすか」「バッテリーでも動かすか」「モバイル回線でも動かすか」を**一本に混ぜて**いた。
/// ADR-80 で 4 軸に分けたのち、ADR-195 で「前面でも動かすか（控えめ）」の軸を**廃止**した——
/// 「操作中は 1 単位ごとに譲る」が常時の挙動なので、前面で動かすかを設定で選ぶ必要が無い。
/// 前面では **20 秒触っていなければ動く**（触れば即譲る）。これで「充電してアプリを開いて
/// いれば進む」が既定になる。
///
/// | 軸 | 設定 | 既定 |
/// |---|---|---|
/// | 自動処理する/しない | `HeavyWorkTiming`（enabled / paused） | enabled |
/// | 電源 | `PowerStateMonitor.policy` | 充電中のみ |
/// | 回線 | `NetworkStateMonitor.policy` | Wi-Fi のみ |
///
/// 本型は 1 つ目の軸（自動処理の有無）と、判定の**純ロジック**（`allows`）だけを持つ。
/// 電源・回線の状態は呼び出し側（`BackgroundYield`）が各モニタから渡す。
public enum HeavyWorkTiming: Int, CaseIterable, Sendable {
    /// 自動処理なし（「今すぐ処理」とデバッグ実行だけ可）。
    case paused = 0
    /// 自動処理あり（実際に動く条件は前面/電源/回線の各設定が決める）。
    case enabled = 1

    /// UserDefaults キー（設定 UI と `BackgroundYield` が共用）。
    public static let defaultsKey = "heavywork.timing"

    /// 旧 5 段階からの移行を一度だけ行うためのフラグキー。
    static let migrationKey = "heavywork.axesMigrated"

    /// 保存値から読む（未設定・範囲外は既定 enabled）。
    /// 旧値（2=chargeActive / 3=battery / 4=unlimited）は移行で 1 に畳まれる。
    public static var current: HeavyWorkTiming {
        let raw = UserDefaults.standard.object(forKey: defaultsKey) as? Int
        guard let raw else { return .enabled }
        return raw == paused.rawValue ? .paused : .enabled
    }

    /// アプリ使用中（フォアグラウンド）に「操作の合間」とみなすアイドル秒数。
    /// 全タッチを UIWindow レベルで捕捉した上での値なので短くても誤発火しない。
    public static let foregroundIdleSeconds: TimeInterval = 20

    // MARK: - 移行（旧 5 段階 → 4 軸）

    /// 旧 5 段階の保存値を各軸へ写す（アプリ起動時に 1 度だけ呼ぶ）。
    /// 既存ユーザーの「意思」を壊さないため、段階から読み取れる意図をそのまま各設定へ移す。
    public static func migrateLegacySettingsIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }
        // 旧値が無い（新規インストール）なら既定のままでよい。
        guard let legacy = defaults.object(forKey: defaultsKey) as? Int else { return }
        let plan = migrationPlan(legacyRawValue: legacy)
        defaults.set(plan.timing.rawValue, forKey: defaultsKey)
        // 電源・回線は既存の独立設定へ写す。**緩める方向にだけ**書く（nil＝触らない）＝
        // ユーザーが既に電源/回線を個別に絞っていた場合、その設定を上書きしない。
        if let power = plan.power { defaults.set(power.rawValue, forKey: PowerStateMonitor.policyKey) }
        if let data = plan.data { defaults.set(data.rawValue, forKey: NetworkStateMonitor.policyKey) }
    }

    /// 移行の内容（純ロジック・テスト対象）。旧 rawValue → 各軸の設定値。
    /// - 旧 0 (paused)       → 自動処理オフ。他は既定のまま。
    /// - 旧 1 (nightly)      → 既定のまま（電源=充電中・回線=Wi-Fi）。
    /// - 旧 2 (chargeActive) → 既定のまま（前面で動かす意思は ADR-195 で常時の挙動になった）。
    /// - 旧 3 (battery)      → 電源=常に。
    /// - 旧 4 (unlimited)    → 電源=常に ＋ 回線=セルラーも。
    public static func migrationPlan(legacyRawValue: Int)
        -> (timing: HeavyWorkTiming, power: BackgroundPowerPolicy?, data: BackgroundDataPolicy?) {
        switch legacyRawValue {
        case 0:  return (.paused, nil, nil)
        case 3:  return (.enabled, .always, nil)
        case 4:  return (.enabled, .always, .unrestricted)
        default: return (.enabled, nil, nil)   // 1（nightly）・2（chargeActive）と未知の値
        }
    }

    // MARK: - 判定（純ロジック・テスト対象）

    /// この設定・状況で重い処理を動かしてよいか。
    /// - Parameters:
    ///   - isAppActive: アプリがフォアグラウンドでアクティブか
    ///   - foregroundIdle: アプリ使用中だが最後のタッチから `foregroundIdleSeconds` 以上経過したか
    ///   - powerAllowed: 電源ポリシー（`PowerStateMonitor.backgroundAllowed()`）を満たすか
    ///   - networkAllowed: 回線ポリシー（`NetworkStateMonitor.networkAllowed()`）を満たすか
    ///   - requiresNetwork: この作業が回線を必要とするか。**端末内写真の顔スキャン・CLIP 埋め込みは
    ///     通信不要なので false**（電源＋非使用だけで走る）。false なら回線条件を課さない。
    public func allows(isAppActive: Bool, foregroundIdle: Bool,
                       powerAllowed: Bool, networkAllowed: Bool,
                       requiresNetwork: Bool = true) -> Bool {
        guard self != .paused else { return false }

        // 前面では「触っていないこと」だけを要求する（ADR-195）。触れば各処理が 1 単位ごとに譲る。
        if isAppActive {
            guard foregroundIdle else { return false }    // 最終タッチから 20 秒未満は動かさない
        }

        guard powerAllowed else { return false }
        // 回線を要する作業のみ課す。ローカル処理（端末内写真）は回線条件なしで走る。
        return requiresNetwork ? networkAllowed : true
    }
}
