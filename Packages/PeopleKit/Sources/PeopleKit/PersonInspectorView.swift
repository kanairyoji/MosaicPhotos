#if canImport(UIKit)
import AutoAlbumCore
import SwiftUI

// MARK: - 人物を調べる（ADR-147・元は Developer Options の「クラスタリングの内訳」）

/// 「この人物は誰と混ざりやすいのか」「中に他人が入っていないか」を見て、その場で直す画面。
///
/// ⚠️ 元は開発者向けの内訳表示だった（ADR-135）。実フィードバック「便利なのでユーザー向けに
/// 格上げしたい」を受けて **ピープルの導線**（人物メニュー・ピープル一覧）へ移し、
/// 数字は残したまま**言葉をユーザー語**にした（cos → 似ている度 %、しきい値 → 必要な近さ）。
/// 置き場所を設定にしなかったのは、これが**設定ではなく特定の人物への操作**だから。
public struct PersonInspectorView: View {
    let peopleEngine: PeopleEngine
    /// 開いた時点の調査対象（人物メニューから開くときに渡す）。
    var initialPerson: PersonInfo?

    public init(peopleEngine: PeopleEngine, initialPerson: PersonInfo? = nil) {
        self.peopleEngine = peopleEngine
        self.initialPerson = initialPerson
    }

    @State private var focus: PersonInfo?
    @State private var report: PersonDecisionReport?
    /// いま調べているクラスタ ID。**読み込み中でも正しい名前を出す**ための単一の出典。
    @State private var focusClusterID: Int?
    @State private var showingAnswerBasis = false
    /// 顔の切り抜きではなく**写真全体**で見る（実フィードバック: 全体像を見たい）。
    @State private var showsWholePhoto = false
    @State private var loading = false
    @State private var showingPicker = false
    /// 「別の人へ移す」対象の顔（間違い候補のタップ）。
    @State private var reassignTarget: PersonOutlierFace?
    /// 統合の確認対象（近傍の行のメニュー）。
    @State private var mergeCandidate: PersonDecisionRow?
    /// 統合が拒否されたときの理由。
    @State private var mergeRejection: String?

    public var body: some View {
        presentations(
            VStack(spacing: 0) {
                // ⚠️ スクロールしても**誰を調べているか**が消えないよう、List の外に出して固定する
                //（実フィードバック: 「下へ送ると調査対象が分からなくなる」）。
                focusHeader
                Divider()
                listContent
            }
        )
            .navigationTitle(L("Inspect Person"))
            .navigationBarTitleDisplayMode(.inline)
            // 問い合わせが重いので、開いている間は顔スキャンに譲らせる（ADR-142）。
            .pausesFaceScan(peopleEngine)
            .task {
                guard focus == nil else { return }
                guard let start = initialPerson ?? peopleEngine.allPeople.first else { return }
                focus = start
                await load(start)
            }
    }

    private var listContent: some View {
        List {
            if let report {
                settingsSection(report)
                statusSection(report.focus)
                neighborSection(report)
                outlierSection(report)
                glossarySection
            } else if loading {
                Section { Text(L("Analyzing…")).foregroundStyle(.secondary) }
            }
        }
    }

    /// ⚠️ シート・アラートを body に直に積むと型チェックが破裂する（この画面で実際に踏んだ）。
    /// 提示だけを別の関数に切り出す。
    private func presentations<V: View>(_ content: V) -> some View {
        content
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
            .sheet(isPresented: $showingAnswerBasis) {
                NavigationStack {
                    AnswerBasisView(peopleEngine: peopleEngine)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(L("Close")) { showingAnswerBasis = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showingPicker) {
                InspectorPersonPicker(people: peopleEngine.allPeople) { person in
                    focus = person
                    Task { await load(person) }
                }
            }
            .alert(L("Combine “\(mergeCandidateName)” into “\(focusName)”?"),
                   isPresented: Binding(get: { mergeCandidate != nil },
                                        set: { if !$0 { mergeCandidate = nil } }),
                   presenting: mergeCandidate) { row in
                Button(L("Cancel"), role: .cancel) { mergeCandidate = nil }
                Button(L("Combine")) { merge(row) }
            } message: { row in
                Text(L("\(row.photoCount) photos will move into “\(focusName)”. If it turns out to be wrong, you can fix it from Manage Faces."))
            }
            .alert(L("Can’t combine"), isPresented: Binding(get: { mergeRejection != nil },
                                                  set: { if !$0 { mergeRejection = nil } })) {
                Button(L("OK")) { mergeRejection = nil }
            } message: {
                Text(mergeRejection ?? "")
            }
    }

    /// 調査対象の表示名（統合先の名前）。
    /// 調べている人物の表示名。
    ///
    /// ⚠️ **読み込んだレポートを正とする**（実フィードバック: 「似ている人へ切り替えたのに
    /// 名前が変わらない」）。以前は `focus`（PersonInfo）だけを見ていたので、切り替え先が
    /// 一覧（`allPeople`）に居ないと nil のままになり、**前の名前が残って見えた**。
    /// 名前は「レポートの名前 → 一覧の表示名 → Person <ID>」の順に決める。
    private var focusName: String {
        guard let id = focusClusterID ?? report?.focus.clusterID else {
            return focus?.displayName ?? L("this person")
        }
        // レポートが**その人物のもの**のときだけ、そこにある名前を使う
        //（切り替え直後は前の人物のレポートが残っているため）。
        if report?.focus.clusterID == id, let name = report?.focus.name, !name.isEmpty { return name }
        return displayName(clusterID: id, name: nil)
    }

    /// 統合確認に出す相手の名前。
    private var mergeCandidateName: String {
        guard let row = mergeCandidate else { return L("this person") }
        return displayName(clusterID: row.clusterID, name: row.name)
    }

    /// クラスタ ID の表示名（名前 → ピープル一覧の表示名 → Person <ID>）。
    private func displayName(clusterID: Int, name: String?) -> String {
        if let name, !name.isEmpty { return name }
        if let person = peopleEngine.allPeople.first(where: { $0.clusterID == clusterID }) {
            return person.displayName
        }
        return "Person \(clusterID)"
    }

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
                mergeRejection = L("Both have names. Clear one of the names first, or use “Group as Same Person”.")
            case .rejectedSamePhoto:
                // ⚠️ 「別人として学習」はしない（ADR-146）。ユーザーは同じ人だと言っている。
                // どの写真がぶつかっているかは、その人物の顔一覧に出る。
                mergeRejection = L("Both faces appear in the same photo, so they can’t be the same person. Tap the row to see the overlapping photos — if the same face was picked up twice, remove one of them.")
                await load(clusterID: destination)
            }
        }
    }

    private func load(_ person: PersonInfo) async {
        await load(clusterID: person.clusterID)
    }

    private func load(clusterID: Int) async {
        // ⚠️ **切り替えた瞬間に見出しを差し替える**。読み込みは数百 ms かかるので、
        // ここで前の人物の名前・数字を残すと「切り替わっていない」ように見える。
        if focusClusterID != clusterID { report = nil }
        focusClusterID = clusterID
        loading = true
        // 切り替え先が一覧に居れば `focus` も合わせる（居なくても名前は ID から出す）。
        if let person = peopleEngine.allPeople.first(where: { $0.clusterID == clusterID }) {
            focus = person
        }
        report = await peopleEngine.decisionReport(clusterID: clusterID, limit: 15)
        loading = false
    }

    /// 画面上部に固定する「調査対象の人物」。代表写真・枚数・状態を一目で出す。
    private var focusHeader: some View {
        HStack(spacing: 12) {
            FaceAvatarImage(refKey: report?.focus.coverRefKey,
                            box: report?.focus.coverBoundingBox, maxPixel: 240)
                .frame(width: 52, height: 52)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Inspecting")).font(.caption2).foregroundStyle(.secondary)
                Text(focusName).font(.headline).lineLimit(1)
                if let report {
                    Text(L("\(report.focus.photoCount) photos ・ \(report.focus.anchorCount) confirmed"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Button(L("Choose Person…")) { showingPicker = true }
                Toggle(L("Show whole photo"), isOn: $showsWholePhoto)
                // 感覚ではなく自分の回答で基準を確かめる導線（ADR-148）。
                Button(L("What your answers say…")) { showingAnswerBasis = true }
                if let focus {
                    Button(L("Analyze Again")) { Task { await load(focus) } }
                }
            } label: {
                Image(systemName: "ellipsis.circle").imageScale(.large)
            }
            .accessibilityLabel(Text(L("Person options")))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func settingsSection(_ report: PersonDecisionReport) -> some View {
        Section {
            let base = percent(report.settings.baseThreshold)
            row(L("Needed to be the same person"), percent(report.settings.threshold),
                detail: L("default \(base)"))
            row(L("People in your library"), "\(report.totalPeople)")
            row(L("Corrections you made"), "\(report.negativeCount)")
        } header: {
            Text(L("How matching is set up"))
        } footer: {
            Text(L("These come from your own corrections. The more you fix, the better they fit your photos."))
        }
    }

    private func statusSection(_ focus: PersonDecisionFocus) -> some View {
        Section {
            row(L("Photos"), "\(focus.photoCount)")
            row(L("Faces you confirmed"), "\(focus.anchorCount)")
            row(L("Cover photo"), focus.hasCover ? L("Chosen") : L("Not chosen"))
            row(L("Grouped as one person"), focus.isGrouped ? L("Yes") : L("No"))
            HStack {
                Text(L("Kept as you left it"))
                Spacer()
                Text(focus.isSeed ? L("Yes") : L("No"))
                    .foregroundStyle(focus.isSeed ? .green : .orange)
            }
            if !focus.isSeed {
                // ⚠️ ここが「いつのまにか変わる」人物の正体。直し方まで書く（ADR-130/132）。
                Text(L("This person has no name and no confirmed face, so the app may reorganize these photos on its own. Give them a name, choose a cover photo, or confirm a face to keep them as they are."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text(L("This person"))
        }
    }

    private func neighborSection(_ report: PersonDecisionReport) -> some View {
        Section {
            ForEach(report.neighbors) { row in
                // ⚠️ 補間の中で関数を呼ばない（`\(percent(x))`）。文字列カタログのキーは
                // 書式指定子に落ちるため、入れ子の括弧があると照合できない（テストが拾えない）。
                let alike = percent(row.similarity)
                let needed = percent(row.required)
                NavigationLink {
                    FaceClusterMembersView(clusterID: row.clusterID,
                                           title: displayName(clusterID: row.clusterID, name: row.name),
                                           focusClusterID: focus?.clusterID ?? -1,
                                           focusName: focusName,
                                           peopleEngine: peopleEngine,
                                           showsWholePhoto: $showsWholePhoto,
                                           onFocus: { picked in
                        // その人物を対象に切り替えて、こちらの内訳を作り直す。
                        focus = peopleEngine.allPeople.first { $0.clusterID == picked }
                        Task { await load(clusterID: picked) }
                    }, onMerge: { merge(row) })
                } label: {
                HStack(spacing: 10) {
                // 「Person 1234」だけでは誰か分からない。代表写真を添える（実フィードバック）。
                FaceAvatarImage(refKey: row.coverRefKey, box: row.coverBoundingBox, maxPixel: 200)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(displayName(clusterID: row.clusterID, name: row.name))
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(L("\(alike) alike")).font(.subheadline.monospacedDigit())
                    }
                    HStack(spacing: 6) {
                        Text(verdictLabel(row.verdict))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(verdictColor(row.verdict))
                        Text(L("needs \(needed)"))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(L("・\(row.photoCount) photos"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if row.inMergeBand {
                        Text(L("Close enough that the app may ask you about this pair."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
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
                        Label(L("This is “\(focusName)” — combine"), systemImage: "person.2.slash")
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button { mergeCandidate = row } label: {
                        Label(L("Same"), systemImage: "arrow.triangle.merge")
                    }
                    .tint(.accentColor)
                }
            }
        } header: {
            Text(L("People who look alike"))
        } footer: {
            Text(L("Tap a row to see that person’s faces. Swipe left or long-press to combine them into the person you are inspecting."))
        }
    }

    /// この人物の中で重心から外れている顔＝**混入の候補**（ADR-137）。
    /// 近傍（他人との距離）だけでは内側に紛れ込んだ顔は見つからないので、内側からも見る。
    @ViewBuilder
    private func outlierSection(_ report: PersonDecisionReport) -> some View {
        // ⚠️ **空でもセクションを出す**（実フィードバック: 「候補が無いのかバグか分からない」）。
        // 消えている画面は「壊れている」と区別が付かない。理由まで書く。
        if report.outliers.isEmpty {
            Section {
                Text(outlierEmptyText(report.outlierStatus))
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text(L("Photos that may be someone else"))
            }
        } else {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], spacing: 6) {
                    ForEach(report.outliers) { face in
                        Button { reassignTarget = face } label: {
                            VStack(spacing: 2) {
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay {
                                        FaceAvatarImage(refKey: face.refKey,
                                                        box: showsWholePhoto ? nil : face.boundingBox,
                                                        maxPixel: 320,
                                                        contentMode: showsWholePhoto ? .fit : .fill)
                                    }
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(percent(face.similarity))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(face.belowThreshold ? .orange : .secondary)
                                if face.confirmed {
                                    Text(L("confirmed")).font(.caption2).foregroundStyle(.green)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text(L("Photos that may be someone else"))
            } footer: {
                Text(L("These faces look least like the rest of this person. Orange means the app would not put this face here today. Tap one to move it to the right person."))
            }
        }
    }

    /// 間違い候補が空のときの説明（＝出ない理由）。
    private func outlierEmptyText(_ status: PersonOutlierStatus) -> String {
        switch status {
        case .computed:
            return L("(None) Every face of this person was checked and none stood out.")
        case .noMembers:
            return L("(None) This person has no faces yet.")
        case .tooManyMembers(let limit, let members):
            return L("(Not checked) This person has \(members) faces, more than the \(limit) this check covers.")
        }
    }

    /// 用語の注記。**画面の数字が何を意味するか**をここで完結させる。
    /// ⚠️ 開発者語（cos・しきい値・マージン・重心）はユーザーには通じない。
    /// 数字は残しつつ、読み手の言葉で言い換える。
    private var glossarySection: some View {
        Section(L("About these numbers")) {
            glossary(L("Alike"),
                     L("How much two faces look alike, as a percentage. 100% is the same face."))
            glossary(L("Needs"),
                     L("How alike two people must be before the app puts them together. It is stricter for people with few photos, so a new person doesn’t swallow someone else."))
            glossary(L("Confirmed face"),
                     L("A face you said belongs to this person — by confirming it, choosing a cover photo, naming the person, or moving a face here. Confirmed faces are never moved away on their own."))
            glossary(L("Kept as you left it"),
                     L("A person with a name, a confirmed face, or a grouping stays exactly as you left it. Others may be reorganized as new photos arrive."))
            glossary(L("Corrections"),
                     L("When you say “not this person”, the app remembers that face and keeps it out. Your corrections also decide how strict the matching is."))
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

    /// 類似度をユーザー向けの百分率にする（cos 0.412 → 41%）。
    /// ⚠️ 内部の尺度（コサイン類似度）をそのまま出しても読めない。桁は落とすが順位は保つ。
    private func percent(_ v: Float) -> String { "\(Int((v * 100).rounded()))%" }

    /// 判定の結論をユーザー語にする（「なぜ一緒にならないか」が読んで分かること）。
    private func verdictLabel(_ v: FaceDecisionVerdict) -> String {
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
            .searchable(text: $query, prompt: L("Search people"))
            .navigationTitle(L("Choose Person"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } }
            }
        }
    }
}

/// 近傍の人物として認識している顔の一覧（デバッグ・読み取り専用）。
/// 「この人物は実際に誰の顔で出来ているのか」を確かめる用。
private struct FaceClusterMembersView: View {
    let clusterID: Int
    let title: String
    /// 調査対象のクラスタ ID（重なりの照合に使う）。
    let focusClusterID: Int
    /// 調査対象の表示名（「この人物は◯◯」の◯◯）。
    let focusName: String
    let peopleEngine: PeopleEngine
    /// 顔の切り抜き／写真全体の切り替え（親と共有する）。
    @Binding var showsWholePhoto: Bool
    /// この人物を内訳の対象に切り替える。
    let onFocus: (Int) -> Void
    /// この人物を調査対象の人物へ統合する。
    let onMerge: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var faces: [PersonInfo.Face] = []
    /// 「別の人へ移す」対象（顔のタップ）。
    @State private var reassignTarget: PersonInfo.Face?
    @State private var confirmingMerge = false
    /// 同じ写真に一緒に写っている箇所（＝統合できない理由）。
    @State private var conflicts: [(refKey: String, first: PersonInfo.Face, second: PersonInfo.Face)] = []

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 3)]

    var body: some View {
        ScrollView {
            if !conflicts.isEmpty { conflictSection }
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(faces) { face in
                    // タップで正しい人物へ移せる（誤りに気づく場所は 1 つではない・ADR-137）。
                    Button { reassignTarget = face } label: {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                FaceAvatarImage(refKey: face.refKey,
                                                box: showsWholePhoto ? nil : face.boundingBox,
                                                maxPixel: 320,
                                                contentMode: showsWholePhoto ? .fit : .fill)
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showsWholePhoto.toggle() } label: {
                    Image(systemName: showsWholePhoto ? "person.crop.square" : "photo")
                }
                .accessibilityLabel(Text(showsWholePhoto ? L("Show face") : L("Show whole photo")))
            }
        }
        // ⚠️ 「対象にする」だけでは**何の対象か分からない**（実フィードバック）。
        // 何が起きるかを書いた**フル幅のボタン**にする（ツールバーだと長い名前が入らない）。
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                // ⚠️ 顔を見て「これは調査対象の本人だった」と分かる場面が本題（実フィードバック）。
                // その判断をこの場で確定できるようにする（一覧の左スワイプ・長押しと同じ操作）。
                Button {
                    confirmingMerge = true
                } label: {
                    Label(L("This is “\(focusName)”"), systemImage: "person.2.slash")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    onFocus(clusterID)
                    dismiss()
                } label: {
                    Label(L("Inspect this person instead"), systemImage: "scope")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                Text(L("Top: combine this person into “\(focusName)”. Bottom: switch the inspection to this person."))
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .background(.bar)
        }
        .alert(L("Combine “\(title)” into “\(focusName)”?"), isPresented: $confirmingMerge) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Combine")) { onMerge(); dismiss() }
        } message: {
            Text(L("\(faces.count) faces will move into “\(focusName)”. If it turns out to be wrong, you can fix it from Manage Faces."))
        }
        .task {
            faces = await peopleEngine.coverCandidates(clusterID: clusterID)
            await reloadConflicts()
        }
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

    /// 「同じ写真に一緒に写っている」ので統合できない箇所を出す（ADR-146）。
    ///
    /// ⚠️ 1 枚に同じ人は 1 回しか写れない——が、**重複検出・写真の中の写真・鏡**では破れる。
    /// 破れているとユーザーは統合できず、しかも**どの写真が原因か分からない**（実フィードバック）。
    /// 写真と両方の顔を並べ、その場で片方を外せるようにする。
    private var conflictSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Photos where both appear"))
                .font(.subheadline.weight(.semibold))
            Text(L("These photos contain a face of “\(focusName)” and a face of this person, so they can’t be the same person. If the same face was picked up twice, remove one of them."))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(conflicts, id: \.refKey) { conflict in
                conflictRow(conflict)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private func conflictRow(
        _ conflict: (refKey: String, first: PersonInfo.Face, second: PersonInfo.Face)
    ) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // 写真全体（box なし）＝どの写真かが分かる。
                FaceAvatarImage(refKey: conflict.refKey, box: nil, maxPixel: 300)
                    .frame(width: 76, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                conflictFace(conflict.first, caption: focusName)
                conflictFace(conflict.second, caption: title)
            }
            HStack(spacing: 8) {
                Button(L("Remove the “\(focusName)” face")) { remove(conflict.first) }
                    .buttonStyle(.bordered).font(.caption)
                Button(L("Remove the “\(title)” face")) { remove(conflict.second) }
                    .buttonStyle(.bordered).font(.caption)
            }
        }
    }

    private func conflictFace(_ face: PersonInfo.Face, caption: String) -> some View {
        VStack(spacing: 2) {
            FaceAvatarImage(refKey: face.refKey,
                            box: showsWholePhoto ? nil : face.boundingBox, maxPixel: 200,
                            contentMode: showsWholePhoto ? .fit : .fill)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// 重なっている顔の片方を人物から外す（新しい人物になる）。外れれば統合できる。
    private func remove(_ face: PersonInfo.Face) {
        Task {
            await peopleEngine.reassignFace(faceID: face.faceID, toClusterID: nil)
            faces = await peopleEngine.coverCandidates(clusterID: clusterID)
            await reloadConflicts()
        }
    }

    private func reloadConflicts() async {
        guard focusClusterID >= 0, focusClusterID != clusterID else { conflicts = []; return }
        conflicts = await peopleEngine.samePhotoConflicts(between: focusClusterID, and: clusterID)
    }

}
#endif
