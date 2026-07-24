import AutoAlbumCore
import SwiftUI

/// 人物レビュー（ADR-46・A1/A2/A3）。iPhone の写真アプリの「この人は◯◯さんですか？」に相当。
/// 判断が割れる（＝学習価値が高い）ケースだけをカードで尋ね、回答が
/// 統合・正例アンカー・負例・しきい値校正の材料になる＝**答えるほど認識精度が上がる**。
/// 初回の一括確認（A3）もこの画面がそのまま担う（ピープルのヘッダーから開く）。
struct FaceReviewView: View {
    let peopleEngine: PeopleEngine

    @Environment(\.dismiss) private var dismiss
    @State private var items: [FaceReviewItem] = []
    @State private var index = 0
    @State private var isLoading = true
    @State private var answered = 0

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(L("Finding faces to review…"))
                } else if index < items.count {
                    cardView(items[index])
                } else {
                    doneView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(L("Review People"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Close")) { dismiss() }
                }
                if !isLoading, index < items.count {
                    ToolbarItem(placement: .primaryAction) {
                        Text(verbatim: "\(index + 1) / \(items.count)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .task {
                items = await peopleEngine.reviewItems()
                isLoading = false
            }
        }
    }

    // MARK: - Card

    @ViewBuilder
    private func cardView(_ item: FaceReviewItem) -> some View {
        VStack(spacing: 24) {
            Spacer()
            switch item {
            case .samePerson(_, let aName, let aFace, _, let bName, let bFace, _):
                HStack(spacing: 24) {
                    personColumn(face: aFace, name: aName)
                    personColumn(face: bFace, name: bName)
                }
                Text(L("Are these the same person?"))
                    .font(.title3.weight(.semibold))

            case .isThisPerson(let face, _, let name, let coverFace, _):
                if let name {
                    // 命名済み: 名前で尋ねられる（誰のことか分かる）。
                    FaceAvatarImage(refKey: face.refKey, box: face.boundingBox, maxPixel: 480)
                        .frame(width: 160, height: 160)
                        .clipShape(Circle())
                    Text(L("Is this “\(name)”?"))
                        .font(.title3.weight(.semibold))
                } else {
                    // 未命名: "Person N" では誰か分からないので、代表の顔と並べて
                    // **見た目だけで**判断できる形にする（実フィードバック対応）。
                    HStack(spacing: 24) {
                        personColumn(face: coverFace, name: "")
                        personColumn(face: face, name: "")
                    }
                    Text(L("Are these the same person?"))
                        .font(.title3.weight(.semibold))
                }
            }

            Text(L("Your answers teach the app — recognition improves as you review."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            HStack(spacing: 12) {
                answerButton(L("No"), systemImage: "xmark", tint: .red) { answer(item, yes: false) }
                answerButton(L("Skip"), systemImage: "arrow.right", tint: .secondary) { advance() }
                answerButton(L("Yes"), systemImage: "checkmark", tint: .green) { answer(item, yes: true) }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func personColumn(face: PersonInfo.Face, name: String) -> some View {
        VStack(spacing: 8) {
            FaceAvatarImage(refKey: face.refKey, box: face.boundingBox, maxPixel: 400)
                .frame(width: 120, height: 120)
                .clipShape(Circle())
            if !name.isEmpty {
                Text(name).font(.subheadline)
            }
        }
    }

    private func answerButton(_ title: String, systemImage: String, tint: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.bordered)
        .tint(tint)
    }

    private var doneView: some View {
        VStack(spacing: 12) {
            Image(systemName: answered > 0 ? "checkmark.seal.fill" : "checkmark.seal")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text(answered > 0 ? L("Thanks! \(answered) answers recorded.")
                              : L("Nothing to review right now."))
                .font(.headline)
            Text(L("The app applies what it learned during the next overnight analysis."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: - Answer

    private func answer(_ item: FaceReviewItem, yes: Bool) {
        answered += 1
        Task {
            switch item {
            case .samePerson(let a, _, _, let b, _, _, _):
                await peopleEngine.answerSamePerson(aClusterID: a, bClusterID: b, same: yes)
            case .isThisPerson(let face, _, _, _, _):
                await peopleEngine.answerIsThisPerson(faceID: face.faceID, yes: yes)
            }
        }
        advance()
    }

    private func advance() {
        // 統合で消えたクラスタに触れるカードをスキップしながら進める（単純化のため
        // 残カードの整合はサーバ側で再検証せず、回答時の store 側 guard に任せる）。
        index += 1
    }
}
