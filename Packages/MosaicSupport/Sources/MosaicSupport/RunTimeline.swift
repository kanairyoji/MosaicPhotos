import Foundation

/// **「アプリがいつ動いて、いつ動かなかったか」だけを書く専用の台帳**（diagnostics-81 の反省）。
///
/// ## なぜ診断ログと分けるのか
/// 「夜に解析が進まない」を調べるのに要るのは、起動・予約・処理枠・セッション・終了理由という
/// **1 日に数十行しか出ない情報**だけ。ところが実機ログ（末尾 256KB）は Dropbox の同期や
/// 顔検出の 1 枚ごとの行で埋まり、実際に diagnostics-81 では**ログ行の 47% が同期のノイズ**で、
/// 肝心の夜間帯が押し出されて消えていた。**流量の桁が違うものを同じファイルに混ぜない**——
/// この台帳は同じ 256KB でも数か月ぶん残る。
///
/// ## もう一つの前提
/// **アプリが動いていない時間のことは、その時間には書けない**。だから「次に動いた瞬間」に
/// 空白について分かることを全部書く：前回どう終わったか（正常／窓の途中）、前回の窓からの経過、
/// そして OS が持っている終了理由（MetricKit の `MXAppExitMetric`）。
public enum RunTimeline {

    /// 台帳ファイル（Developer Options で閲覧・共有できる）。
    public static let log: DiagnosticsLog = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return DiagnosticsLog(fileURL: dir.appendingPathComponent("run-timeline.log"))
    }()

    /// 1 行記録する。
    public static func record(_ line: String) { log.append(line) }

    /// **落ちる直前**の 1 行（同期書き込み）。
    public static func recordNow(_ line: String) { log.appendNow(line) }

    // MARK: - 実行状態のパンくず（プロセスが死んでも残る）

    private static let stateKey = "runTimeline.state"
    private static let stateAtKey = "runTimeline.stateAt"

    /// いま何をしているかを残す。プロセスが突然終わっても、次の起動でここから推測できる。
    /// - Parameter state: `"idle"` / `"window"`（処理枠の中）/ `"session"`（今すぐ解析）など。
    public static func noteState(_ state: String) {
        let d = UserDefaults.standard
        d.set(state, forKey: stateKey)
        d.set(Date().timeIntervalSinceReferenceDate, forKey: stateAtKey)
    }

    /// 前回の実行がどう終わったか（起動時に 1 回呼ぶ）。
    public static func previousRunSummary(now: Date = Date()) -> String? {
        let d = UserDefaults.standard
        guard let state = d.string(forKey: stateKey) else { return nil }
        let raw = d.double(forKey: stateAtKey)
        let at = raw > 0 ? Date(timeIntervalSinceReferenceDate: raw) : nil
        return summary(state: state, at: at, now: now)
    }

    /// 前回の終わり方の要約（純ロジック・テスト対象）。
    ///
    /// `idle` 以外で終わっている＝**中断されたまま終了した**（jetsam・ウォッチドッグ・強制終了）。
    /// 「窓の途中で消えた」は、OS が以後しばらく窓をくれない理由になり得るので必ず残す。
    static func summary(state: String, at: Date?, now: Date) -> String? {
        let elapsed = at.map { Int(now.timeIntervalSince($0) / 60) }
        let ago = elapsed.map { "\($0) 分前" } ?? "時刻不明"
        switch state {
        case "idle":
            return nil                       // 正常に終わっている＝書くことは無い
        case "window":
            return "前回は**処理枠の途中**で終了している（\(ago)）。iOS による終了（メモリ・ウォッチドッグ）か強制終了の疑い"
        case "session":
            return "前回は**解析セッションの途中**で終了している（\(ago)）"
        default:
            return "前回は '\(state)' の途中で終了している（\(ago)）"
        }
    }

    // MARK: - MetricKit の終了理由（OS が持っている唯一の答え）

    /// 終了カウンタの要約（純ロジック・テスト対象）。0 の項目は書かない。
    /// - Parameters:
    ///   - background: 背面での終了カウンタ（キーは下の `label` に合わせた識別子）。
    ///   - foreground: 前面での終了カウンタ。
    public static func exitSummary(background: [String: Int], foreground: [String: Int]) -> String {
        func part(_ counts: [String: Int]) -> String {
            let items = counts.filter { $0.value > 0 }
                .sorted { $0.key < $1.key }
                .map { "\(label(for: $0.key))=\($0.value)" }
            return items.isEmpty ? "なし" : items.joined(separator: " ")
        }
        return "背面終了[\(part(background))] 前面終了[\(part(foreground))]"
    }

    /// 終了理由の日本語ラベル（読み手が原因を即断できるように）。
    static func label(for key: String) -> String {
        switch key {
        case "memoryResourceLimit":       return "メモリ上限(jetsam)"
        case "memoryPressure":            return "メモリ圧迫"
        case "cpuResourceLimit":          return "CPU 上限"
        case "watchdog":                  return "ウォッチドッグ"
        case "backgroundTaskTimeout":     return "BGTask 期限超過"
        case "suspendedWithLockedFile":   return "ロック中ファイルで吊るされ"
        case "badAccess":                 return "不正アクセス"
        case "illegalInstruction":        return "不正命令"
        case "abnormal":                  return "異常終了"
        case "normal":                    return "正常終了"
        default:                          return key
        }
    }
}
