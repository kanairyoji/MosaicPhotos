import AutoAlbumCore
import PeopleKit
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
    /// 「別の人へ移す」対象の顔（間違い候補のタップ）。
    @State private var reassignTarget: PersonOutlierFace?
    /// 統合の確認対象（近傍の行のメニュー）。
    @State private var mergeCandidate: PersonDecisionRow?
    /// 統合が拒否されたときの理由。
    @State private var mergeRejection: String?

    var body: some View {
        List {
            focusSection
            if let report {
                settingsSection(report)
                statusSection(report.focus)
                neighborSection(report)
                outlierSection(report)
                glossarySection
            } else if loading {
                Section { Text("計算中…").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("クラスタリングの内訳")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $reassignTarget) { face in
            FaceReassignPickerView(faceID: face.faceID, refKey: face.refKey,
                                   boundingBox: face.boundingBox,
                                   currentClusterID: focus?.clusterID ?? -1,
                                   peopleEngine: peopleEngine) { target in
                Task {
                    await peopleEngine.reassignFace(faceID: face.faceID, toClusterID: target)
                    if let focus { await load(clusterID: focus.clusterID) }
                }
            }
        }
        .sheet(isPresented: $showingPicker) {
            InspectorPersonPicker(people: peopleEngine.allPeople) { person in
                focus = person
                Task { await load(person) }
            }
        }
        .alert("「\(mergeCandidate?.name ?? "この人物")」を「\(focusName)」に統合しますか？",
               isPresented: Binding(get: { mergeCandidate != nil },
                                    set: { if !$0 { mergeCandidate = nil } }),
               presenting: mergeCandidate) { row in
            Button("キャンセル", role: .cancel) { mergeCandidate = nil }
            Button("統合する") { merge(row) }
        } message: { row in
            Text("\(row.photoCount) 枚の写真が「\(focusName)」に入ります。"
                 + "取り違えていた場合は、顔の管理から戻せます。")
        }
        .alert("統合できません", isPresented: Binding(get: { mergeRejection != nil },
                                              set: { if !$0 { mergeRejection = nil } })) {
            Button("OK") { mergeRejection = nil }
        } message: {
            Text(mergeRejection ?? "")
        }
        .task {
            guard focus == nil, let first = peopleEngine.allPeople.first else { return }
            focus = first
            await load(first)
        }
    }

    /// 調査対象の表示名（統合先の名前）。
    private var focusName: String { focus?.displayName ?? "この人物" }

    /// 近傍の人物を調査対象の人物へ統合する。拒否されたら理由を出す。
    private func merge(_ row: PersonDecisionRow) {
        let source = row.clusterID
        guard let destination = focus?.clusterID else { return }
        mergeCandidate = nil
        Task {
            switch await peopleEngine.mergePerson(from: source, into: destination) {
            case .merged:
                await load(clusterID: destination)
            case .rejectedDifferentNames:
                mergeRejection = "両方に別々の名前が付いています。"
                    + "先にどちらかの名前を消すか、「同じ人として束ねる」を使ってください。"
            case .rejectedSamePhoto:
                mergeRejection = "同じ写真に一緒に写っています（同一人物ではあり得ません）。"
                    + "別人として記録しました。"
                await load(clusterID: destination)
            }
        }
    }

    private func load(_ person: PersonInfo) async {
        await load(clusterID: person.clusterID)
    }

    private func load(clusterID: Int) async {
        loading = true
        report = await peopleEngine.decisionReport(clusterID: clusterID, limit: 15)
        loading = false
    }

    private var focusSection: some View {
        Section {
            Button {
                showingPicker = true
            } label: {
                HStack {
                    Text("調査対象の人物")
                    Spacer()
                    Text(focus?.displayName ?? "選ぶ").foregroundStyle(.secondary)
                }
            }
            if let focus {
                Button("この人物を再解析") { Task { await load(focus) } }
            }
        } footer: {
            Text("「調査対象の人物」から見た近傍と、その人物の中で重心から外れている顔を、"
                 + "割り当て規則（しきい値・サイズ適応マージン・マージンゲート・負例・同一写真）で"
                 + "判定して並べます。解析そのものは台帳を変更しません。")
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
        Section {
            ForEach(report.neighbors) { row in
                NavigationLink {
                    FaceClusterMembersView(clusterID: row.clusterID,
                                           title: row.name ?? "Person \(row.clusterID)",
                                           peopleEngine: peopleEngine) { picked in
                        // その人物を対象に切り替えて、こちらの内訳を作り直す。
                        focus = peopleEngine.allPeople.first { $0.clusterID == picked }
                        Task { await load(clusterID: picked) }
                    }
                } label: {
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
                // ⚠️ 実フィードバック: 「近傍に出てきた Person XXXX は、全部**統合すべき人**だった」。
                // 近傍を眺めて終わりではなく、その場で畳めるようにする。
                .contextMenu {
                    Button {
                        mergeCandidate = row
                    } label: {
                        Label("この人物を「\(focusName)」に統合する", systemImage: "person.2.slash")
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button { mergeCandidate = row } label: {
                        Label("統合", systemImage: "arrow.triangle.merge")
                    }
                    .tint(.accentColor)
                }
            }
        } header: {
            Text("近傍（類似度の高い順）")
        } footer: {
            Text("行をタップすると、その人物として認識している顔の一覧が出ます"
                 + "（そこから調査対象を切り替えられます）。左スワイプまたは長押しで、"
                 + "その人物を調査対象の人物に統合できます。")
        }
    }

    /// この人物の中で重心から外れている顔＝**混入の候補**（ADR-137）。
    /// 近傍（他人との距離）だけでは内側に紛れ込んだ顔は見つからないので、内側からも見る。
    @ViewBuilder
    private func outlierSection(_ report: PersonDecisionReport) -> some View {
        if !report.outliers.isEmpty {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], spacing: 6) {
                    ForEach(report.outliers) { face in
                        Button { reassignTarget = face } label: {
                            VStack(spacing: 2) {
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay {
                                        FaceAvatarImage(refKey: face.refKey, box: face.boundingBox,
                                                        maxPixel: 320)
                                    }
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(String(format: "%.3f", face.similarity))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(face.belowThreshold ? .orange : .secondary)
                                if face.confirmed {
                                    Text("確認済み").font(.caption2).foregroundStyle(.green)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("間違い候補（重心から遠い順）")
            } footer: {
                Text("この人物の顔のうち、重心から遠いものです。数字は重心との類似度で、"
                     + "オレンジは「いまのしきい値なら合流しない」顔＝混入の可能性が高いもの。"
                     + "タップすると別の人物へ移せます（確認済みはユーザーが本人と表明した顔）。")
            }
        }
    }

    /// 用語の注記。**画面の数字が何を意味するか**をここで完結させる
    /// ——別ドキュメントを見に行かないと読めない表は、チューニングでは使われない。
    private var glossarySection: some View {
        Section("用語") {
            glossary("cos（コサイン類似度）", "顔を数百次元のベクトルにしたときの「向きの近さ」。"
                     + "1.00 が同じ向き、0.00 が無関係。距離ではなく向きで測るので、"
                     + "明るさや顔の大きさの違いに強い。この画面の数字はすべてこの尺度。")
            glossary("しきい値", "合流してよい cos の下限。ユーザーの修正から校正され、"
                     + "プロファイルの可動域内で上下する（校正前の値が「既定」）。")
            glossary("実効しきい値（表の「必要」）", "その相手に入るために実際に要る cos。"
                     + "＝しきい値＋サイズ適応の上乗せ。表の「必要 0.398」がこれで、"
                     + "cos がこれ未満なら合流しない。")
            glossary("ゲート幅", "マージンゲートの幅。1 位と 2 位の cos の差がこれ未満なら、"
                     + "紛らわしいのでどちらにも入れない。")
            glossary("重心", "その人物の顔ベクトルの平均（品質で重み付け）。人物の「中心」で、"
                     + "新しい顔はこれとの近さ（cos 類似度）で判定される。"
                     + "「重心に寄与」はその平均に入っている顔の数（品質フロア未満の顔は"
                     + "表示だけの所属なので入らない）。")
            glossary("アンカー（確認顔）", "ユーザーが「この人だ」と表明した顔"
                     + "（1 対 1 の確認・代表写真の選択・名前付け・別の人への付け替え・統合）。"
                     + "重心とは別に個別の「見本」として使われ、重心から外れた角度・年齢の顔も"
                     + "拾える。再クラスタでは動かない錨になる（ADR-130/132）。")
            glossary("種（再クラスタで残る側）", "名前・アンカー・束ねのどれかがある人物。"
                     + "種はメンバーごと保たれ、無い人物は毎回ばらして割り当て直される。")
            glossary("サイズ適応の上乗せ", "小さい人物ほど合流を厳しくする仕組み。"
                     + "実効しきい値＝しきい値＋上乗せで、メンバー 1 人のとき最大、"
                     + "成熟枚数以上で 0。育ち始めのクラスタが似た他人を吸い込むのを防ぐ。")
            glossary("マージンゲート", "1 位と 2 位の人物がどちらも閾値を超え、"
                     + "その差がゲート幅未満なら「どちらにも入れない」。"
                     + "「両方にそこそこ似ている」顔（兄弟・親子）を取り違えないための保険。")
            glossary("負例", "「この人ではない」と外した顔の記録。似た顔が同じ人物へ入ろうと"
                     + "したときに拒否する。再スキャンやモデル更新を跨いで効く（ADR-45）。")
            glossary("統合候補の帯", "「同じ人ですか？」のレビューに出す類似度の下限。"
                     + "自動合流はしないが、人に尋ねる価値がある範囲。")
        }
    }

    private func glossary(_ term: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(term).font(.subheadline.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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
            .navigationTitle("調査対象の人物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
        }
    }
}

/// 近傍の人物として認識している顔の一覧（デバッグ・読み取り専用）。
/// 「この人物は実際に誰の顔で出来ているのか」を確かめる用。
private struct FaceClusterMembersView: View {
    let clusterID: Int
    let title: String
    let peopleEngine: PeopleEngine
    /// この人物を内訳の対象に切り替える。
    let onFocus: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var faces: [PersonInfo.Face] = []
    /// 「別の人へ移す」対象（顔のタップ）。
    @State private var reassignTarget: PersonInfo.Face?

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 3)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(faces) { face in
                    // タップで正しい人物へ移せる（誤りに気づく場所は 1 つではない・ADR-137）。
                    Button { reassignTarget = face } label: {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                FaceAvatarImage(refKey: face.refKey, box: face.boundingBox, maxPixel: 320)
                            }
                            .clipped()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
        }
        .navigationTitle("\(title)（\(faces.count)）")
        .navigationBarTitleDisplayMode(.inline)
        // ⚠️ 「対象にする」だけでは**何の対象か分からない**（実フィードバック）。
        // 何が起きるかを書いた**フル幅のボタン**にする（ツールバーだと長い名前が入らない）。
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                Button {
                    onFocus(clusterID)
                    dismiss()
                } label: {
                    Label("この人物を調査対象にして再解析", systemImage: "scope")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                Text("内訳の画面が、この人物から見た近傍・間違い候補に切り替わります。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .background(.bar)
        }
        .task { faces = await peopleEngine.coverCandidates(clusterID: clusterID) }
        .sheet(item: $reassignTarget) { face in
            FaceReassignPickerView(faceID: face.faceID, refKey: face.refKey,
                                   boundingBox: face.boundingBox,
                                   currentClusterID: clusterID,
                                   peopleEngine: peopleEngine) { target in
                Task {
                    await peopleEngine.reassignFace(faceID: face.faceID, toClusterID: target)
                    faces = await peopleEngine.coverCandidates(clusterID: clusterID)
                }
            }
        }
    }
}
