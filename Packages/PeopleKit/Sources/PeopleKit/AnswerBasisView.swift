#if canImport(UIKit)
import AutoAlbumCore
import SwiftUI

// MARK: - あなたの回答から見た基準（ADR-148）

/// 「同じ人」「別人」と答えたペアの似ている度が、実際どう分かれているかを見る画面。
///
/// ⚠️ しきい値は**感覚で動かさない**。「厳しすぎる気がする」で動かすと、直すほど別の壊れ方をする
/// （ADR-140/141 で経験した）。ここはあなた自身の回答を材料にした、**あなたの写真での適正値**。
public struct AnswerBasisView: View {
    let peopleEngine: PeopleEngine

    public init(peopleEngine: PeopleEngine) {
        self.peopleEngine = peopleEngine
    }

    @State private var pair: AnswerSimilarityProfile?
    @State private var face: AnswerSimilarityProfile?
    @State private var calibrated: Float?
    @State private var base: Float?
    @State private var askBar: Float?

    public var body: some View {
        List {
            if let pair {
                profileSection(pair, title: L("Person to person"),
                               note: L("From “Are these the same person?” answers. The app never combines two people on its own — it only asks."))
            }
            if let face {
                profileSection(face, title: L("Face to person"),
                               note: L("From “Is this face this person?” answers. This is the scale used when a new face joins a person."))
            }
            if let calibrated, let base, let askBar {
                let defaultText = percent(base)
                Section(L("In use now")) {
                    row(L("Needed to be the same person"), percent(calibrated),
                        detail: L("default \(defaultText)"))
                    row(L("Asks you about pairs above"), percent(askBar))
                }
            }
            Section {
                Text(L("If your “same person” answers sit well above the value in use, matching is stricter than your own judgement. These numbers are measured, not guessed — use them when changing the rules."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L("What your answers say"))
        .navigationBarTitleDisplayMode(.inline)
        .pausesFaceScan(peopleEngine)
        .task {
            pair = await peopleEngine.answerSimilarityProfile(kind: .personPair)
            face = await peopleEngine.answerSimilarityProfile(kind: .faceToPerson)
            let current = await peopleEngine.currentThresholds()
            calibrated = current.calibrated
            base = current.base
            askBar = current.askBar
        }
    }

    @ViewBuilder
    private func profileSection(_ profile: AnswerSimilarityProfile,
                                title: String, note: String) -> some View {
        Section {
            if profile.same.count == 0 && profile.different.count == 0 {
                Text(L("(None) You haven’t answered any of these yet."))
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                sideRow(L("Same person"), profile.same, color: .green)
                sideRow(L("Different people"), profile.different, color: .orange)
                if let bar = profile.bestBar {
                    let missed = profile.sameBelowBar
                    let wrong = profile.differentAboveBar
                    row(L("Best split of your answers"), percent(bar),
                        detail: L("\(missed) missed ・ \(wrong) wrongly included"))
                } else {
                    Text(L("Answer a few more to see the best split."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text(note)
        }
    }

    /// 片側（同じ人／別人）の要約とヒストグラム。
    private func sideRow(_ label: String, _ side: AnswerSimilaritySide, color: Color) -> some View {
        let count = side.count
        let middle = percent(side.median)
        let low = percent(side.p10)
        let high = percent(side.p90)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline.weight(.medium))
                Spacer()
                Text(L("\(count) answers")).font(.caption).foregroundStyle(.secondary)
            }
            if side.count > 0 {
                Text(L("middle \(middle) ・ range \(low)–\(high)"))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                histogram(side, color: color)
            }
        }
        .padding(.vertical, 2)
    }

    /// 10% 刻みの分布（横棒）。件数の最大を 1 とした相対長。
    private func histogram(_ side: AnswerSimilaritySide, color: Color) -> some View {
        let peak = max(1, side.histogram.max() ?? 1)
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(side.histogram.enumerated()).reversed(), id: \.offset) { bucket in
                if bucket.element > 0 {
                    HStack(spacing: 6) {
                        Text(verbatim: "\(bucket.offset * 10)–\(bucket.offset * 10 + 10)%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .trailing)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color.opacity(0.75))
                            .frame(width: max(2, CGFloat(bucket.element) / CGFloat(peak) * 140),
                                   height: 8)
                        Text(verbatim: "\(bucket.element)")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func row(_ title: String, _ value: String, detail: String? = nil) -> some View {
        HStack {
            Text(title)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(value).monospacedDigit()
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func percent(_ v: Float) -> String { "\(Int((v * 100).rounded()))%" }
}
#endif
