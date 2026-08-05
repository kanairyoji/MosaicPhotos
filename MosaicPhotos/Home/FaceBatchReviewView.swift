import AutoAlbumCore
import SwiftUI

/// 一括レビュー（ADR-67）。「この人と同じ人を、まとめて選ぶ」。
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
    @State private var rejected: Set<Int> = []
    @State private var mergedTotal = 0
    @State private var isApplying = false

    private static let columns = [GridItem(.adaptive(minimum: 84), spacing: 12)]

    private var selectedIDs: [Int] {
        (item?.candidates ?? []).map(\.clusterID).filter { !rejected.contains($0) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(L("Looking for people to merge…"))
                } else if let item {
                    content(item)
                } else {
                    doneView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                if rejected.contains(candidate.clusterID) {
                                    rejected.remove(candidate.clusterID)
                                } else {
                                    rejected.insert(candidate.clusterID)
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
            Text(L("Tap the ones that are someone else to remove them."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func candidateCell(_ candidate: FaceBatchReviewItem.Candidate) -> some View {
        let isRejected = rejected.contains(candidate.clusterID)
        return VStack(spacing: 4) {
            FaceAvatarImage(refKey: candidate.face.refKey, box: candidate.face.boundingBox,
                            maxPixel: 400)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .opacity(isRejected ? 0.35 : 1)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isRejected ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isRejected ? Color.red : Color.green)
                        .font(.title3)
                        .padding(3)
                }
            Text(verbatim: "\(candidate.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func footer(_ item: FaceBatchReviewItem) -> some View {
        VStack(spacing: 8) {
            Text(L("\(selectedIDs.count) will be merged, \(rejected.count) marked as someone else."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                Task { await apply(item) }
            } label: {
                Label(L("Merge"), systemImage: "person.2.badge.plus")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isApplying || (selectedIDs.isEmpty && rejected.isEmpty))
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
            Text(L("Answers are applied right away, and the next overnight analysis uses them too."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(L("Find more")) { Task { await load(anchor: nil) } }
                .buttonStyle(.bordered)
                .padding(.top, 8)
        }
    }

    // MARK: - Actions

    private func load(anchor: Int?) async {
        isLoading = true
        rejected = []
        item = await peopleEngine.batchReviewItem(anchorClusterID: anchor)
        isLoading = false
    }

    /// 回答を適用し、**同じアンカーで**次の候補を取りに行く（連鎖）。
    /// 統合でアンカーの重心が育つので、さっきは届かなかった時期のクラスタが入ってくる。
    private func apply(_ item: FaceBatchReviewItem) async {
        isApplying = true
        let same = selectedIDs
        await peopleEngine.answerBatch(anchorClusterID: item.anchorClusterID,
                                       same: same, notSame: Array(rejected))
        mergedTotal += same.count
        isApplying = false
        await load(anchor: item.anchorClusterID)
    }
}
