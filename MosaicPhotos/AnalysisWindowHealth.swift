import Foundation
import MosaicSupport

/// **処理枠（BGProcessingTask）が来ているか**の健全性判定（純ロジック・diagnostics-81）。
///
/// 「なぜ解析が進まないか」の条件そのものは `BackgroundYield`（ADR-196 のゲート表）が唯一の出典。
/// ここに残すのは**アプリ側の条件では説明できない沈黙**——条件は全部満たしているのに、
/// OS が長いあいだ枠をくれない場合の判定だけ。
///
/// 旧 `AnalysisBlockerDiagnosis` は条件そのものをゲートとは別に再実装しており、
/// ゲートが閉じているのに画面が「すべての条件を満たしています」と言える状態になっていた（ADR-196）。
enum AnalysisWindowHealth {

    /// 「条件は満たしているのに長く枠が来ていない」とみなす閾値。
    ///
    /// Apple は「予約から起動まで何時間もかかり得る」と明記しているので、短い空白は正常。
    /// ただし**半日以上**空くのは、アプリを強制終了した・端末が jetsam でアプリを落とした等の
    /// 兆候なので、利用者に「今すぐ解析」を勧める（実機 diagnostics-81 では 12 時間空いた）。
    static let starvationThresholdMinutes = 12 * 60

    /// 枠が飢えているか。`blockers` が空（＝アプリ側の理由が無い）ときだけ判定する。
    static func isStarved(blockers: [BackgroundYield.Blocker], minutesSinceLastWindow: Int?) -> Bool {
        guard blockers.isEmpty, let minutes = minutesSinceLastWindow else { return false }
        return minutes >= starvationThresholdMinutes
    }
}
