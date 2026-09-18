import Foundation

/// **アプリを離れたときに解析を続けるか**の設定（ADR-193）。
///
/// ## 何を選んでいるのか
/// 選んでいるのは「表示」ではなく「継続タスクを使う場面」。iOS 26 の
/// `BGContinuedProcessingTask` は**進捗 UI（ロック画面・Dynamic Island）を OS が必ず出す**ので、
/// アプリ側から非表示にはできない（そもそも進捗を報告しないタスクは OS が殺す）。
/// だから「インジケータがうるさい」への答えは、**継続タスクを使う場面を減らす**ことだけ。
///
/// ⚠️ 軸を混ぜない（ADR-80 の教訓）。ここで決めるのは「アプリを離れても続けるか」だけで、
/// 電源・回線・自動処理のオン/オフは既存の 4 軸のまま。**夜間の処理枠はどの段でも動く**。
enum AnalysisContinuation: Int, CaseIterable, Sendable {
    /// 既定。手動でも自動再開でも継続タスクを使う（最速・インジケータが出る）。
    case always = 0
    /// 「今すぐ解析」を押したときだけ継続タスクを使う。自動再開は画面を開いている間だけ。
    case manualOnly = 1
    /// 継続タスクを使わない。AI 解析の状況を開いている間だけ走る（インジケータは出ない）。
    case whileOpen = 2

    static let `default`: AnalysisContinuation = .always

    static var current: AnalysisContinuation {
        AnalysisContinuation(rawValue: UserDefaults.standard.integer(forKey: AppSettingsKeys.analysisContinuation))
            ?? .default
    }
}

/// 継続タスクと自動再開の可否（純ロジック・テスト対象）。
enum AnalysisContinuationPolicy {

    /// OS の継続タスクを要求するか（＝アプリを離れても続けるか・インジケータが出るか）。
    static func requestsContinuedTask(_ level: AnalysisContinuation, autoResume: Bool) -> Bool {
        switch level {
        case .always:     return true
        case .manualOnly: return !autoResume      // 押したときだけ粘る
        case .whileOpen:  return false            // 常に前面のみ
        }
    }

    /// 中断された解析を**自動で**再開してよいか。
    ///
    /// - **電源接続が必須**（全段共通）: 外出先でアプリを開いただけで解析が走り出し、電池を
    ///   食う／インジケータが出るのを防ぐ。手動で押したときは従来どおり免除
    ///   （電池 20% 未満での自動停止という安全弁は別に効いている）。
    /// - 継続タスクを使わない段（`manualOnly` の自動再開・`whileOpen`）は、**AI 解析の状況を
    ///   開いているときだけ**。見ていない前面で重い処理を走らせない（ADR-25）。
    /// - Parameter wasManual: その中断が「利用者が自分で押したセッション」のものか。
    ///   押した本人が**いまこの画面を見ている**なら、電源は要求しない——この画面から
    ///   「処理のタイミング」へ進んで戻っただけで解析が永久に失われるのを防ぐ（レビュー指摘）。
    static func allowsAutoResume(_ level: AnalysisContinuation,
                                 onPower: Bool,
                                 statusScreenOpen: Bool,
                                 wasManual: Bool = false) -> Bool {
        if wasManual, statusScreenOpen { return true }
        guard onPower else { return false }
        return requestsContinuedTask(level, autoResume: true) ? true : statusScreenOpen
    }
}
