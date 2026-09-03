#if canImport(UIKit)
import AutoAlbumCore
import SwiftUI

// MARK: - 人物を調べる: 表示の言い換え
//
// ⚠️ この画面の要点は**数字をユーザー語にする**こと（ADR-147: cos → 似ている度 %、
// しきい値 → 必要な近さ）。言い換えの規則が散らばると表記が揺れるので 1 箇所に集める。

extension PersonInspectorView {

    // MARK: - 表示ヘルパ

    func row(_ title: String, _ value: String, detail: String? = nil) -> some View {
        HStack {
            Text(title)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(value).monospacedDigit()
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    /// 類似度をユーザー向けの百分率にする（cos 0.412 → 41%）。
    /// ⚠️ 内部の尺度（コサイン類似度）をそのまま出しても読めない。桁は落とすが順位は保つ。
    /// ⚠️ `Int(_:)` は **NaN / 無限大で trap する**（Swift の仕様）。壊れた埋め込みや
    /// 空の重心から来た類似度をそのまま流すと、表示するだけでアプリが落ちる。
    func percent(_ v: Float) -> String {
        guard v.isFinite else { return "—" }
        return "\(Int((v * 100).rounded()))%"
    }

    /// 判定の結論をユーザー語にする（「なぜ一緒にならないか」が読んで分かること）。
    func verdictLabel(_ v: FaceDecisionVerdict) -> String {
        switch v {
        case .joins: return L("Would be put together")
        case .samePhoto: return L("Both in the same photo")
        case .differentNames: return L("Different names")
        case .blockedByMargin: return L("Too close to another person")
        case .blockedBySizeMargin: return L("Too few photos to be sure")
        case .belowThreshold: return L("Not alike enough")
        case .blockedByNegative: return L("You said they are different")
        }
    }

    func verdictColor(_ v: FaceDecisionVerdict) -> Color {
        switch v {
        case .joins: return .green
        case .blockedByMargin, .blockedBySizeMargin: return .orange
        case .blockedByNegative: return .blue
        case .belowThreshold, .samePhoto, .differentNames: return .secondary
        }
    }
}
#endif
