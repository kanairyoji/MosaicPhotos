#if canImport(MetricKit) && os(iOS)
import Foundation
import MetricKit

/// MetricKit のハング診断を診断ログへ落とす（ADR-106）。
///
/// 動機: 実機で「復帰直後・アルバム作成時にメインが 9〜12 秒止まる」が 3 セッション連続で
/// 再現しているのに、自前のウォッチドッグでは**何がメインを塞いだか**特定できない
/// （直前のログ行との突き合わせでは、モデルロード等の同時進行イベントと区別がつかない）。
/// MetricKit の `MXHangDiagnostic` は **OS がハング時に採取したメインスレッドの呼び出し木**を
/// 持っており、これが唯一の決定的な証拠になる。
///
/// 制約: 診断ペイロードは即時ではなく**次回起動時など OS の任意タイミング**で届く。
/// 届いたら要約（ハング秒数＋スタック上位フレーム）を `DiagnosticsLog` へ書く＝
/// いつもの診断ログの共有フローにそのまま乗る。
public final class HangDiagnostics: NSObject, MXMetricManagerSubscriber {
    public static let shared = HangDiagnostics()

    /// `Diagnostics.install()` から呼ぶ（アプリ起動時に 1 回）。
    public func install() {
        MXMetricManager.shared.add(self)
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for hang in payload.hangDiagnostics ?? [] {
                let seconds = hang.hangDuration.converted(to: .seconds).value
                DiagnosticsLog.shared.append(String(format: "HANG-DIAG: %.1fs のハング（OS 採取）",
                                                    seconds))
                // 呼び出し木の JSON から主要フレームを抜き出す（全文は巨大なので上位のみ）。
                let json = hang.callStackTree.jsonRepresentation()
                for line in Self.topFrames(fromCallStackJSON: json, limit: 14) {
                    DiagnosticsLog.shared.append("HANG-DIAG:   \(line)")
                }
            }
        }
    }

    public func didReceive(_ payloads: [MXMetricPayload]) {}

    /// MetricKit の callStackTree JSON から「自アプリのフレームを優先して」上位を抜き出す（純・テスト対象）。
    /// フォーマット: {"callStacks":[{"callStackRootFrames":[{binaryName, offsetIntoBinaryTextSegment,
    /// symbol?, subFrames:[...]}]}]}。シンボルが無いことも多いので binaryName+offset を残す
    /// （後で .dSYM で引ける）。
    static func topFrames(fromCallStackJSON data: Data, limit: Int) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stacks = root["callStacks"] as? [[String: Any]] else { return ["(解析不能)"] }
        var lines: [String] = []
        func walk(_ frame: [String: Any], depth: Int) {
            guard lines.count < limit else { return }
            let binary = frame["binaryName"] as? String ?? "?"
            let offset = frame["offsetIntoBinaryTextSegment"] as? Int ?? 0
            let symbol = frame["symbol"] as? String
            let indent = String(repeating: " ", count: min(depth, 8))
            lines.append("\(indent)\(binary) +\(offset)\(symbol.map { " \($0)" } ?? "")")
            for sub in frame["subFrames"] as? [[String: Any]] ?? [] {
                walk(sub, depth: depth + 1)
            }
        }
        // 最初のスタック（メインスレッド相当）だけで十分。
        if let first = stacks.first,
           let roots = first["callStackRootFrames"] as? [[String: Any]] {
            for frame in roots { walk(frame, depth: 0) }
        }
        return lines.isEmpty ? ["(フレーム無し)"] : lines
    }
}
#endif
