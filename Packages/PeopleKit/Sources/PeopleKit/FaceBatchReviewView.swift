#if canImport(UIKit)
import AutoAlbumCore
import MosaicSupport
import PhotoSourceKit
import SwiftUI

/// 一括レビュー（ADR-68）。「この人と同じ人を、まとめて選ぶ」。
///
/// 1 対 1 の確認カード（`FaceReviewView`）は **1 回答＝1 統合**なので、成長期の子供で
/// 数百〜数千に分裂したライブラリでは追いつかない。この画面は基準の人物に似たクラスタを
/// 並べ、**違うものだけ外して一度に統合**する。統合するたびに基準が育ち、次の回では
/// さらに遠い時期のクラスタが候補に入る（＝ユーザーの確認を種にした連鎖）。
public struct FaceBatchReviewView: View {
    public let peopleEngine: PeopleEngine
    /// 特定の人物を基準にしたいとき（人物一覧から開いた場合）。
    public var anchorClusterID: Int?

    @Environment(\.dismiss) private var dismiss
    @State private var item: FaceBatchReviewItem?
    @State private var isLoading = true
    /// 実行中の候補探索。キャンセル（＝待たされている側の出口）に使う。
    @State private var loadTask: Task<FaceBatchReviewItem?, Never>?
    /// ⚠️ 既定は**未選択**。既定で全選択にすると、誤タップひとつで最大 24 クラスタが
    /// 統合されてしまう（統合は取り消しが効かない）。「すべて選ぶ」を 1 タップ用意して
    /// 効率は保ちつつ、破壊的操作は必ずユーザーの明示で起きるようにする。
    @State private var selected: Set<Int> = []
    @State private var mergedTotal = 0
    /// 統合を拒否された件数（別名どうし・同一写真で共起）。理由を伝えないと
    /// 「選んだのに減らない」に見えるため表示する。
    @State private var rejectedTotal = 0
    @State private var isApplying = false
    /// 「次の人へ」で送った基準。これを除いて次の人物を選ぶ（ADR-68 追補4）。
    /// 基準が固定されたままだと、真の一致を出し切った後は候補が全部別人になり機能が死ぬ。
    @State private var visitedAnchors: Set<Int> = []
    /// 基準ごとの「出したが選ばれなかった候補」。除外しないと同じ顔が延々と出続ける。
    @State private var shownCandidates: [Int: Set<Int>] = [:]

    private static let columns = [GridItem(.adaptive(minimum: 84), spacing: 12)]

    private var allSelected: Bool {
        guard let item, !item.candidates.isEmpty else { return false }
        return selected.count == item.candidates.count
    }


    public init(peopleEngine: PeopleEngine, anchorClusterID: Int? = nil) {
        self.peopleEngine = peopleEngine
        self.anchorClusterID = anchorClusterID
    }

    public var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    // ⚠️ 待っている間の出口を必ず出す（実フィードバック）。中断は
                    // `loadTask` の cancel で、候補生成側も `Task.isCancelled` を見て降りる。
                    Color.clear.busyOverlay(true, text: L("Finding similar people…"),
                                            cancel: (label: L("Cancel"), action: cancelLoad))
                } else if let item {
                    content(item)
                } else {
                    doneView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 一括統合は N 人ぶんのクラスタ移動＋同一写真違反の修復＋一覧再構築を伴い、
            // 実機で数百ms メインが止まる（diagnostics-40）。止まっている間こそ見せたいので、
            // レンダーサーバ駆動のスピナーを重ねる（ADR-96）。
            .busyOverlay(isApplying, text: L("Merging…"))
            .navigationTitle(L("Confirm together"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Close")) { dismiss() }
                }
                // まとめて確認は 1 回の「決定」で数十件が動く。取り違えに気づいたときの出口を出す。
                if let undoLabel = peopleEngine.undoLabel {
                    ToolbarItem(placement: .primaryAction) {
                        Button { undoLast() } label: {
                            Label(L("Undo"), systemImage: "arrow.uturn.backward")
                        }
                        .accessibilityHint(Text(verbatim: undoLabel))
                    }
                }
            }
            .task {
                // まとめて確認中は人物一覧の再発行を保留（回答ごとの 2〜4 秒ハング対策・diagnostics-51）。
                peopleEngine.beginPeopleReloadHold()
                await load(anchor: anchorClusterID)
            }
            .onDisappear { peopleEngine.endPeopleReloadHold() }
        }
    }

    // MARK: - Content

    private func content(_ item: FaceBatchReviewItem) -> some View {
        VStack(spacing: 0) {
            header(item)
            if item.candidates.contains(where: \.preselected) {
                Text(L("The most alike ones are already selected — uncheck any that are wrong."))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
            ScrollView {
                LazyVGrid(columns: Self.columns, spacing: 12) {
                    ForEach(item.candidates) { candidate in
                        candidateCell(candidate)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selected.contains(candidate.clusterID) {
                                    selected.remove(candidate.clusterID)
                                } else {
                                    selected.insert(candidate.clusterID)
                                }
                            }
                    }
                }
                .padding(16)
            }
            footer(item)
        }
    }

    private func header(_ item: FaceBatchReviewItem) -> some View {
        VStack(spacing: 10) {
            FaceAvatarImage(refKey: item.anchorFace.refKey, box: item.anchorFace.boundingBox,
                            maxPixel: 480)
                .frame(width: 96, height: 96)
                .clipShape(Circle())
            if item.anchorName.isEmpty {
                Text(L("Which of these are the same person as above?"))
                    .font(.headline)
            } else {
                Text(L("Which of these are “\(item.anchorName)”?"))
                    .font(.headline)
            }
            Text(L("Tap the ones that are the same person."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func candidateCell(_ candidate: FaceBatchReviewItem.Candidate) -> some View {
        let isSelected = selected.contains(candidate.clusterID)
        return VStack(spacing: 4) {
            FaceAvatarImage(refKey: candidate.face.refKey, box: candidate.face.boundingBox,
                            maxPixel: 400)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                }
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .font(.title3)
                            .padding(3)
                    }
                }
            Text(verbatim: "\(candidate.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// 下部の操作領域。
    ///
    /// ⚠️ 配置の意図（実フィードバック）: 以前は「全て選択」「次の人物へ」が文字だけのボタンで、
    /// タップ領域が文字の高さしかなく（HIG の最小 44pt を大きく下回る）、しかも確定操作である
    /// 「N 件をまとめる」との間隔が 8pt しか無かった。補助操作を押したつもりで**統合してしまう**
    /// 配置だったので、(1) 補助操作を 44pt の枠付きボタンにし、(2) 区切り線と余白で確定操作から
    /// はっきり離す。統合はやり直しが面倒（顔の移動＋修正ジャーナルへの記録）なので、
    /// 「押すつもりが無いのに押せてしまう」状態を作らない。
    private func footer(_ item: FaceBatchReviewItem) -> some View {
        VStack(spacing: 0) {
            // 補助操作: 押し間違えても取り返しがつく（選択の切替／この人物を飛ばす）。
            HStack(spacing: 12) {
                Button {
                    selected = allSelected ? [] : Set(item.candidates.map(\.clusterID))
                } label: {
                    Text(allSelected ? L("Clear all") : L("Select all"))
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(isApplying)

                // 候補が全部別人のときの出口。この基準を終えて別の人物へ移る。
                Button {
                    Task { await skipAnchor(item) }
                } label: {
                    Text(L("Next person"))
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(isApplying)
            }

            Divider().padding(.top, 18)

            // 確定操作。補助操作から区切り線＋上下 18pt ぶん離す。
            Button {
                Task { await apply(item) }
            } label: {
                Label(L("Merge \(selected.count)"), systemImage: "person.2.badge.plus")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isApplying || selected.isEmpty)
            .padding(.top, 18)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    private var doneView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text(mergedTotal > 0 ? L("Merged \(mergedTotal) entries.")
                                 : L("Nothing left to merge right now."))
                .font(.headline)
            if rejectedTotal > 0 {
                Text(L("\(rejectedTotal) were kept separate because they have different names or appear together in the same photo."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Text(L("Answers are applied right away, and the next overnight analysis uses them too."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(L("Find more")) {
                Task {
                    // 出し切ったら最初から見直せるようにする（統合で顔ぶれが変わっているため）。
                    visitedAnchors = []
                    shownCandidates = [:]
                    await load(anchor: nil)
                }
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)
        }
    }

    // MARK: - Actions

    /// 次の候補を読み込む。
    ///
    /// ⚠️ **先に画面を切り替えてから**探し始める（実フィードバック: 「次の人へ」を押しても
    /// なかなか画面が変わらず固まって見える）。候補の生成は人物数に比例して重く、
    /// 1,000 人規模では数秒かかる。フラグを立てた直後に処理へ入ると、SwiftUI が描画する前に
    /// 待ちに入ってしまい「押したのに何も起きない」に見える。`runShowingBusy` が
    /// 表示を確定させるまで数フレーム譲るので、以後は待っている間もスピナーが回る。
    private func load(anchor: Int?) async {
        // 直前の人物のグリッドを残さない（残ると「まだ切り替わっていない」に見える）。
        item = nil
        selected = []
        let found = await runCancellable(isBusy: $isLoading, task: $loadTask) { () -> FaceBatchReviewItem? in
            let t0 = PerfTrace.nowNs()
            let found = await peopleEngine.batchReviewItem(
                anchorClusterID: anchor,
                excludingAnchors: visitedAnchors,
                excludingCandidates: anchor.flatMap { shownCandidates[$0] } ?? [])
            // センサー: 人物数に比例して伸びる。実機で何秒かかっているかを残す。
            PerfTrace.logSpan("people.batchReview.load", ms: PerfTrace.msSince(t0),
                              detail: "anchor=\(anchor.map(String.init) ?? "auto")")
            return found
        }
        // キャンセルされた回は何も反映しない（`nil`）。
        if let found {
            item = found
            // ⚠️ 似ている度が高い候補は**チェックを付けた状態**で出す（ADR-153）。
            // 実機の回答では、この帯の 98% が「同じ人」だった。ただし家族には 0.88〜0.92 で
            // 別人の対も実在するので、**自動では結合しない**——外せる形で見せる。
            selected = Set((found?.candidates ?? []).filter(\.preselected).map(\.clusterID))
        }
    }

    /// 直前の「決定」を取り消し、同じ人物のグリッドを引き直す。
    /// まとめて確認は 1 回で数十件が動くので、取り違えに気づいたときの出口を必ず出す。
    private func undoLast() {
        Task {
            let anchor = item?.anchorClusterID
            guard await peopleEngine.undoLastAnswer() != nil else { return }
            mergedTotal = max(0, mergedTotal - 1)
            await load(anchor: anchor)
        }
    }

    /// 探索を中断して閉じる（待たされている側の出口）。
    private func cancelLoad() {
        cancelRunning(isBusy: $isLoading, task: $loadTask)
        dismiss()
    }

    /// 回答を適用し、**同じアンカーで**次の候補を取りに行く（連鎖）。
    /// 統合でアンカーの重心が育つので、さっきは届かなかった時期のクラスタが入ってくる。
    private func apply(_ item: FaceBatchReviewItem) async {
        isApplying = true
        let same = Array(selected)
        // 負例（別人記録）はここでは作らない。未選択は「別人と答えた」ではなく
        // 「選ばなかった」だけなので、修正ジャーナルに混ぜると学習が濁る。
        // 明示的な「いいえ」は 1 対 1 のレビュー（FaceReviewView）で受ける。
        // ただし**同じ候補を出し続けない**よう、出題済みとして覚えておく。
        noteShown(item, keeping: selected)
        let rejected = await peopleEngine.answerBatch(anchorClusterID: item.anchorClusterID,
                                                      same: same, notSame: [])
        mergedTotal += same.count - rejected
        rejectedTotal += rejected
        isApplying = false
        await load(anchor: item.anchorClusterID)
    }

    /// この基準は終わりにして別の人物へ移る（候補が全部別人のときの出口）。
    private func skipAnchor(_ item: FaceBatchReviewItem) async {
        noteShown(item, keeping: [])
        visitedAnchors.insert(item.anchorClusterID)
        await load(anchor: nil)
    }

    /// 出題済みの候補を記録する（統合した分は消えるので覚えなくてよい）。
    private func noteShown(_ item: FaceBatchReviewItem, keeping merged: Set<Int>) {
        let ids = item.candidates.map(\.clusterID).filter { !merged.contains($0) }
        shownCandidates[item.anchorClusterID, default: []].formUnion(ids)
    }
}
#endif
