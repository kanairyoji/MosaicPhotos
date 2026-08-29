import AutoAlbumCore
import SwiftUI

// MARK: - クラスタリング判定の内訳（Developer Options・ADR-135）

/// 「なぜこの人と合流しないのか」を数字で見る画面（デバッグ・読み取り専用）。
///
/// ⚠️ チューニングの手掛かりは類似度そのものではなく、**そこに何が上乗せされたか**にある。
/// 乗っ取り（ADR-130）も学習消失（ADR-134）も、効いていたのは cos ではなく
/// 「サイズ適応マージン」「種になれるか」「負例が効いているか」だった。近さの図だけでは
/// そこが見えないので、判定に使った値をそのまま並べる。
struct FaceClusterInspectorView: View {
    let peopleEngine: PeopleEngine

    @State private var focus: PersonInfo?
    @State private var report: PersonDecisionReport?
    @State private var loading = false
    @State private var showingPicker = false

    var body: some View {
        List {
            focusSection
            if let report {
                settingsSection(report)
                statusSection(report.focus)
                neighborSection(report)
            } else if loading {
                Section { Text("計算中…").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("クラスタリングの内訳")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPicker) {
            InspectorPersonPicker(people: peopleEngine.allPeople) { person in
                focus = person
                Task { await load(person) }
            }
        }
        .task {
            guard focus == nil, let first = peopleEngine.allPeople.first else { return }
            focus = first
            await load(first)
        }
    }

    private func load(_ person: PersonInfo) async {
        loading = true
        report = await peopleEngine.decisionReport(clusterID: person.clusterID, limit: 15)
        loading = false
    }

    private var focusSection: some View {
        Section {
            Button {
                showingPicker = true
            } label: {
                HStack {
                    Text("対象の人物")
                    Spacer()
                    Text(focus?.displayName ?? "選ぶ").foregroundStyle(.secondary)
                }
            }
            if let focus {
                Button("再計算") { Task { await load(focus) } }
            }
        } footer: {
            Text("選んだ人物から見た近傍を、割り当て規則（しきい値・サイズ適応マージン・"
                 + "マージンゲート・負例・同一写真）で判定して並べます。台帳は変更しません。")
        }
    }

    private func settingsSection(_ report: PersonDecisionReport) -> some View {
        Section("いま効いている値") {
            row("しきい値（校正後）", value(report.settings.threshold),
                detail: "既定 \(value(report.settings.baseThreshold))")
            row("マージンゲート幅", value(report.settings.assignMargin))
            row("サイズ適応の最大上乗せ", value(report.settings.sizeAdaptiveMarginMax),
                detail: "\(report.settings.matureCount) 枚で 0")
            row("負例の「同一人物」線", value(report.settings.negativeSameThreshold))
            row("統合候補の下限", value(report.settings.mergeBandFloor))
            row("人物数", "\(report.totalPeople)")
            row("学習した負例", "\(report.negativeCount)")
        }
    }

    private func statusSection(_ focus: PersonDecisionFocus) -> some View {
        Section("この人物の状態") {
            row("写真", "\(focus.photoCount)")
            row("重心に寄与", "\(focus.centroidCount)",
                detail: "サイズ適応の入力（\(fmt(sizeMarginText(focus)))）")
            row("アンカー（確認顔）", "\(focus.anchorCount)")
            row("代表写真", focus.hasCover ? "あり" : "なし")
            row("束ね", focus.isGrouped ? "あり" : "なし")
            HStack {
                Text("再クラスタの種")
                Spacer()
                Text(focus.isSeed ? "なる" : "ならない")
                    .foregroundStyle(focus.isSeed ? .green : .orange)
            }
            if !focus.isSeed {
                Text("名前もアンカーも束ねも無いので、再クラスタのたびにメンバーが割り当て直されます"
                     + "（名前を付ける・代表写真を選ぶ・確認する のどれかで固定されます）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func neighborSection(_ report: PersonDecisionReport) -> some View {
        Section("近傍（類似度の高い順）") {
            ForEach(report.neighbors) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.name ?? "Person \(row.clusterID)")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text("cos \(value(row.similarity))").font(.subheadline.monospacedDigit())
                    }
                    HStack(spacing: 6) {
                        Text(verdictLabel(row.verdict))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(verdictColor(row.verdict))
                        Text("必要 \(value(row.required))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text("・\(row.photoCount)枚 / 重心\(row.centroidCount) / アンカー\(row.anchorCount)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if row.inMergeBand {
                        Text("統合候補の帯に入っている（レビューに出得る）")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - 表示ヘルパ

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

    private func value(_ v: Float) -> String { String(format: "%.3f", v) }
    private func fmt(_ s: String) -> String { s }

    private func sizeMarginText(_ focus: PersonDecisionFocus) -> String {
        guard let report else { return "-" }
        return "上乗せ \(value(report.settings.sizeMargin(forCount: focus.centroidCount)))"
    }

    private func verdictLabel(_ v: FaceDecisionVerdict) -> String {
        switch v {
        case .joins: return "合流する"
        case .samePhoto: return "同じ写真に一緒（別人）"
        case .differentNames: return "別々の名前（別人と表明済み）"
        case .blockedByMargin(let gap): return String(format: "マージンゲート（差 %.3f）", gap)
        case .blockedBySizeMargin: return "サイズ適応の上乗せで届かない"
        case .belowThreshold: return "しきい値に届かない"
        case .blockedByNegative: return "負例が拒否"
        }
    }

    private func verdictColor(_ v: FaceDecisionVerdict) -> Color {
        switch v {
        case .joins: return .green
        case .blockedByMargin, .blockedBySizeMargin: return .orange
        case .blockedByNegative: return .blue
        case .belowThreshold, .samePhoto, .differentNames: return .secondary
        }
    }
}

/// 対象人物を選ぶ（枚数降順・名前検索）。
private struct InspectorPersonPicker: View {
    let people: [PersonInfo]
    let onPick: (PersonInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [PersonInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return people }
        return people.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { person in
                Button {
                    onPick(person); dismiss()
                } label: {
                    HStack {
                        Text(person.displayName).foregroundStyle(.primary)
                        Spacer()
                        Text("\(person.count)").foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $query, prompt: "人物を検索")
            .navigationTitle("対象の人物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
        }
    }
}
