import Foundation

/// 重い処理（AI 索引・顔認識・アルバム生成）を**いつ動かすか**のユーザー設定（5 段階）。
/// 「いつ動くか」（本設定）と「動くときの強さ」（`BackgroundProcessing` の速度段階）は別軸。
///
/// 段階は単調に条件を緩める（上げるほどユーザーへの影響が出る）:
///   paused        自動処理なし（「今すぐ処理」だけ可）
///   nightly       電源＋Wi-Fi＋アプリ非使用時のみ（既定・体感ゼロ＝ADR-25）
///   chargeActive  ＋アプリ使用中も操作の合間に（電源＋Wi-Fi・タッチで即停止）
///   battery       ＋バッテリーでも（Wi-Fi・残量に配慮）
///   unlimited     ＋モバイル回線でも（制限なし）
///
/// どの段階でも**安全弁は常時有効**: 低電力モード・メモリ圧迫・（バッテリー時）残量 20% 未満では動かない。
public enum HeavyWorkTiming: Int, CaseIterable, Sendable {
    case paused = 0
    case nightly = 1        // 既定
    case chargeActive = 2
    case battery = 3
    case unlimited = 4

    /// UserDefaults キー（設定 UI と BackgroundYield が共用）。
    public static let defaultsKey = "heavywork.timing"

    /// 保存値から読む（未設定・範囲外は既定 nightly）。
    public static var current: HeavyWorkTiming {
        HeavyWorkTiming(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .nightly
    }

    /// アプリ使用中（フォアグラウンド）に「操作の合間」とみなすアイドル秒数。
    /// 全タッチを UIWindow レベルで捕捉した上での値なので短くても誤発火しない。
    public static let foregroundIdleSeconds: TimeInterval = 20

    /// バッテリー実行時に要求する最低残量（充電中は不問）。
    public static let minimumBatteryLevel: Float = 0.20

    // MARK: - 判定（純ロジック・テスト対象）

    /// この段階・状況で重い処理を動かしてよいか。
    /// - Parameters:
    ///   - isOnPower: 電源接続中か
    ///   - isLowPowerMode: 低電力モードか（常時ブロック）
    ///   - isOnWiFi: Wi-Fi 接続中か
    ///   - isReachable: 何らかの回線があるか（unlimited 用）
    ///   - isAppActive: アプリがフォアグラウンドでアクティブか
    ///   - foregroundIdle: アプリ使用中だが最後のタッチから `foregroundIdleSeconds` 以上経過したか
    ///   - batteryLevel: 残量（0...1。取得不可は 1 を渡す）
    public func allows(isOnPower: Bool, isLowPowerMode: Bool,
                       isOnWiFi: Bool, isReachable: Bool,
                       isAppActive: Bool, foregroundIdle: Bool,
                       batteryLevel: Float) -> Bool {
        guard self != .paused, !isLowPowerMode else { return false }

        // 前面で操作中（タッチから間もない）はどの段階でも動かさない。
        let usageOK = !isAppActive || foregroundIdle
        // ただし nightly は前面では一切動かさない（合間も不可）。
        if self == .nightly && isAppActive { return false }
        guard usageOK else { return false }

        // 電源/残量。バッテリー実行を許す段階でも残量が少なければ動かさない。
        let powerOK = isOnPower
            || (self >= .battery && batteryLevel >= Self.minimumBatteryLevel)
        guard powerOK else { return false }

        // 回線。unlimited だけモバイル回線も許す（ローカル写真の処理も回線条件に含める＝
        // 挙動を段階の説明どおり単純に保つ。クラウド写真の Wi-Fi 従属は既存ポリシーが重ねて守る）。
        let networkOK = self >= .unlimited ? isReachable : isOnWiFi
        return networkOK
    }
}

extension HeavyWorkTiming: Comparable {
    public static func < (a: HeavyWorkTiming, b: HeavyWorkTiming) -> Bool { a.rawValue < b.rawValue }
}
