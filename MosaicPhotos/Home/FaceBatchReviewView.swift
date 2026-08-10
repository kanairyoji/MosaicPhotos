import AutoAlbumCore
import PhotoSourceKit
import SwiftUI

/// 一括レビュー（ADR-68）。「この人と同じ人を、まとめて選ぶ」。
///
/// 1 対 1 の確認カード（`FaceReviewView`）は **1 回答＝1 統合**なので、成長期の子供で
/// 数百〜数千に分裂したライブラリでは追いつかない。この画面は基準の人物に似たクラスタを
/// 並べ、**違うものだけ外して一度に統合**する。統合するたびに基準が育ち、次の回では
/// さらに遠い時期のクラスタが候補に入る（＝ユーザーの確認を種にした連鎖）。
struct FaceBatchReviewView: View {
    let peopleEngine: PeopleEngine
    /// 特定の人物を基準にしたいとき（人物一覧から開いた場合）。
    var anchorClusterID: Int?

    @Environment(\.dismiss) private var dismiss
    @State private var item: FaceBatchReviewItem?
    @State private var isLoading = true
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

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    Color.clear.busyOverlay(true, text: L("Looking for people to merge…"))
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
            }
            .task { await load(anchor: anchorClusterID) }
        }
    }

    // MARK: - Content

    private func content(_ item: FaceBatchReviewItem) -> some View {
        VStack(spacing: 0) {
            header(item)
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

    private func footer(_ item: FaceBatchReviewItem) -> some View {
        VStack(spacing: 8) {
            HStack {
                Button(allSelected ? L("Clear all") : L("Select all")) {
                    selected = allSelected ? [] : Set(item.candidates.map(\.clusterID))
                }
                Spacer()
                // 候補が全部別人のときの出口。この基準を終えて別の人物へ移る。
                Button(L("Next person")) { Task { await skipAnchor(item) } }
                    .disabled(isApplying)
            }
            .font(.subheadline)
            Button {
                Task { await apply(item) }
            } label: {
                Label(L("Merge \(selected.count)"), systemImage: "person.2.badge.plus")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isApplying || selected.isEmpty)
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

    private func load(anchor: Int?) async {
        isLoading = true
        selected = []
        item = await peopleEngine.batchReviewItem(
            anchorClusterID: anchor,
            excludingAnchors: visitedAnchors,
            excludingCandidates: anchor.flatMap { shownCandidates[$0] } ?? [])
        isLoading = false
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
