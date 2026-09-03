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
/// ⚠️ 格納プロパティと補助メソッドは **internal**（`private` にしない）。
/// 見た目（`+Sections`）と言い換え（`+Labels`）を別ファイルの extension に置いており、
/// `private` はファイル内に限られるため参照できない（`HomeView` / `HomeSections` と同じ方針）。
public struct PersonInspectorView: View {
    let peopleEngine: PeopleEngine
    /// 開いた時点の調査対象（人物メニューから開くときに渡す）。
    var initialPerson: PersonInfo?

    public init(peopleEngine: PeopleEngine, initialPerson: PersonInfo? = nil) {
        self.peopleEngine = peopleEngine
        self.initialPerson = initialPerson
    }

    @State var focus: PersonInfo?
    @State var report: PersonDecisionReport?
    /// いま調べているクラスタ ID。**読み込み中でも正しい名前を出す**ための単一の出典。
    @State var focusClusterID: Int?
    @State var showingAnswerBasis = false
    /// 顔の切り抜きではなく**写真全体**で見る（実フィードバック: 全体像を見たい）。
    @State var showsWholePhoto = false
    /// 断片をまとめた結果（件数を知らせる）。
    @State var absorbMessage: String?
    /// 表示件数。⚠️ **足りなければ増やせる**ようにする（実フィードバック: 次の候補も見たい）。
    /// ページ送りではなく「さらに表示」にしたのは、比べながら見る画面で**前の並びが消えない**方が
    /// 使いやすいから（戻る操作も要らない）。
    @State var neighborLimit = Self.neighborPageSize
    @State var outlierLimit = Self.outlierPageSize

    static let neighborPageSize = 15
    static let outlierPageSize = 24
    /// 間違い候補の 1 行あたりの枚数（List の中では列数を固定して高さを決め打ちにする）。
    static let outlierColumns = 4
    @State var loading = false
    @State var showingPicker = false
    /// 「別の人へ移す」対象の顔（間違い候補のタップ）。
    @State var reassignTarget: PersonOutlierFace?
    /// 統合の確認対象（近傍の行のメニュー）。
    @State var mergeCandidate: PersonDecisionRow?
    /// 統合が拒否されたときの理由。
    @State var mergeRejection: String?

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

    var listContent: some View {
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
    func presentations<V: View>(_ content: V) -> some View {
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
            .alert(L("Tidy up small groups"), isPresented: Binding(
                get: { absorbMessage != nil }, set: { if !$0 { absorbMessage = nil } })) {
                Button(L("OK")) { absorbMessage = nil }
            } message: {
                Text(absorbMessage ?? "")
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
    var focusName: String {
        guard let id = focusClusterID ?? report?.focus.clusterID else {
            return focus?.displayName ?? L("this person")
        }
        // レポートが**その人物のもの**のときだけ、そこにある名前を使う
        //（切り替え直後は前の人物のレポートが残っているため）。
        if report?.focus.clusterID == id, let name = report?.focus.name, !name.isEmpty { return name }
        return displayName(clusterID: id, name: nil)
    }

    /// 統合確認に出す相手の名前。
    var mergeCandidateName: String {
        guard let row = mergeCandidate else { return L("this person") }
        return displayName(clusterID: row.clusterID, name: row.name)
    }

    /// クラスタ ID の表示名（名前 → ピープル一覧の表示名 → Person <ID>）。
    func displayName(clusterID: Int, name: String?) -> String {
        if let name, !name.isEmpty { return name }
        if let person = peopleEngine.allPeople.first(where: { $0.clusterID == clusterID }) {
            return person.displayName
        }
        return "Person \(clusterID)"
    }

    /// 近傍の人物を調査対象の人物へ統合する。拒否されたら理由を出す。
    func merge(_ row: PersonDecisionRow) {
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

    /// 1〜2 枚の断片を、確立した人物へまとめる（ADR-154）。
    func absorbFragments() {
        Task {
            let result = await peopleEngine.absorbFragments()
            let absorbed = result.absorbed
            let people = result.people
            let skipped = result.skipped
            let tooBig = result.skippedTooBig
            absorbMessage = absorbed == 0
                ? L("Nothing to tidy up. \(skipped) small groups were left alone because another person is just as close, and \(tooBig) are bigger than this tidy-up handles.")
                : L("Moved \(absorbed) small groups into \(people) people. \(skipped) were left alone, and \(tooBig) are bigger than this tidy-up handles.")
            if let focus { await load(clusterID: focus.clusterID) }
        }
    }

    func load(_ person: PersonInfo) async {
        await load(clusterID: person.clusterID)
    }

    /// 表示件数だけを変えて読み直す（対象は同じなので、見出しや並びを消さない）。
    func reload(clusterID: Int) async {
        loading = true
        report = await peopleEngine.decisionReport(clusterID: clusterID, limit: neighborLimit,
                                                   outlierLimit: outlierLimit)
        loading = false
    }

    func load(clusterID: Int) async {
        // ⚠️ **切り替えた瞬間に見出しを差し替える**。読み込みは数百 ms かかるので、
        // ここで前の人物の名前・数字を残すと「切り替わっていない」ように見える。
        if focusClusterID != clusterID {
            report = nil
            // 別の人物へ切り替えたら表示件数は最初に戻す（前の人の「もっと見る」を持ち越さない）。
            neighborLimit = Self.neighborPageSize
            outlierLimit = Self.outlierPageSize
        }
        focusClusterID = clusterID
        loading = true
        // 切り替え先が一覧に居れば `focus` も合わせる（居なくても名前は ID から出す）。
        if let person = peopleEngine.allPeople.first(where: { $0.clusterID == clusterID }) {
            focus = person
        }
        report = await peopleEngine.decisionReport(clusterID: clusterID, limit: neighborLimit,
                                                   outlierLimit: outlierLimit)
        loading = false
    }
}
#endif
