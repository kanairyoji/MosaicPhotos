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
    /// このカードの顔画像が揃ったか。揃うまではカードを出さず、回答もさせない
    /// （前の質問の顔を見たまま答えてしまうのを防ぐ）。次カードは先読みするので通常は一瞬。
    @State private var cardReady = false
    /// 顔だけでは判断が付かないとき、写真全体に切り替える（ADR-91）。
    /// 後ろ姿・小さい顔・似た兄弟は、周りの状況（服・場所・一緒に写っている人）が決め手になる。
    /// カードをまたいで維持する（毎回押し直さなくてよい）。
    @State private var showsWholePhoto = false

    /// 顔アバターの読み込みサイズ。**先読みとキャッシュキーを一致させるため**ここで一元管理する
    /// （表示側と数値がずれると先読みが効かず、毎回プレースホルダから始まる）。
    private static let columnPixel: CGFloat = 400
    private static let singlePixel: CGFloat = 480

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(L("Finding faces to review…"))
                } else if index < items.count {
                    let item = items[index]
                    // カードごとに identity を分ける＝回答して次へ進んだら**作り直す**
                    // （画像の @State を持ち越さない）。
                    cardView(item)
                        .id(item.id)
                        .task(id: item.id) {
                            cardReady = false
                            await preloadAvatars(of: item)
                            cardReady = true
                            prefetchNextAvatars()
                        }
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
            .task { await load() }
            // 表示したカードを記録する（3 回見せても答えられなかった質問は以後出さず、
            // 次点の候補に切り替える＝「毎回同じ写真を聞かれる」の対策）。
            .task(id: index) {
                guard !isLoading, index > 0, index < items.count else { return }
                peopleEngine.noteReviewShown(itemID: items[index].id)
            }
        }
    }

    /// レビュー候補を取り込む。完了画面の「Find more」からも呼べるようにしてある
    /// （スキャンの進行につれて候補は増えるので、シートを閉じ直さずに次を探せる）。
    private func load() async {
        isLoading = true
        items = await peopleEngine.reviewItems()
        index = 0
        isLoading = false
        if let first = items.first { peopleEngine.noteReviewShown(itemID: first.id) }
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

            case .splitCluster(_, let name, let faceA, let faceB, _, _):
                // 事後監査（ADR-69）: 1 人物の中に 2 つの塊が見つかった。
                // 見た目は samePerson と同じ「2 枚を並べて尋ねる」カードにする。
                HStack(spacing: 24) {
                    personColumn(face: faceA, name: "")
                    personColumn(face: faceB, name: "")
                }
                if let name {
                    Text(L("Are both of these “\(name)”?"))
                        .font(.title3.weight(.semibold))
                } else {
                    Text(L("Are these the same person?"))
                        .font(.title3.weight(.semibold))
                }

            case .isThisPerson(let face, _, let name, let coverFace, _):
                if let name {
                    // 命名済み: 名前で尋ねられる（誰のことか分かる）。
                    FaceAvatarImage(refKey: face.refKey,
                                    box: showsWholePhoto ? nil : face.boundingBox,
                                    maxPixel: Self.singlePixel)
                        .frame(width: 160, height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: showsWholePhoto ? 14 : 80,
                                                    style: .continuous))
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

            wholePhotoToggle

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
        // 顔が出るまではカードを見せず、回答も受け付けない（レイアウトは保つので跳ねない）。
        .opacity(cardReady ? 1 : 0)
        .disabled(!cardReady)
        .overlay { if !cardReady { ProgressView() } }
    }

    // MARK: - Avatar preload

    /// カードに出る顔アバターの読み込み指定（表示側と同じ maxPixel を使う＝キャッシュキー一致）。
    private func avatarSpecs(of item: FaceReviewItem) -> [(refKey: String?, box: CGRect?, pixel: CGFloat)] {
        switch item {
        case .samePerson(_, _, let aFace, _, _, let bFace, _):
            return [(aFace.refKey, avatarBox(aFace), Self.columnPixel),
                    (bFace.refKey, avatarBox(bFace), Self.columnPixel)]
        case .splitCluster(_, _, let faceA, let faceB, _, _):
            return [(faceA.refKey, avatarBox(faceA), Self.columnPixel),
                    (faceB.refKey, avatarBox(faceB), Self.columnPixel)]
        case .isThisPerson(let face, _, let name, let coverFace, _):
            if name != nil {
                return [(face.refKey, avatarBox(face), Self.singlePixel)]
            }
            return [(coverFace.refKey, avatarBox(coverFace), Self.columnPixel),
                    (face.refKey, avatarBox(face), Self.columnPixel)]
        }
    }

    /// このカードの顔を**描画前に**揃える。
    private func preloadAvatars(of item: FaceReviewItem) async {
        for spec in avatarSpecs(of: item) {
            _ = await FaceAvatarCache.load(refKey: spec.refKey, box: spec.box, maxPixel: spec.pixel)
        }
    }

    /// 次のカードを先読みしておく（回答直後の待ちを実質ゼロにする）。
    private func prefetchNextAvatars() {
        let next = index + 1
        guard next < items.count else { return }
        for spec in avatarSpecs(of: items[next]) {
            FaceAvatarCache.prefetch(refKey: spec.refKey, box: spec.box, maxPixel: spec.pixel)
        }
    }

    /// 表示モードに応じた切り抜き矩形（全体表示は nil＝切り抜かない）。
    /// **先読みと表示で同じ値**を使う（キャッシュキーに box が入るため、ずれると先読みが無駄になる）。
    private func avatarBox(_ face: PersonInfo.Face) -> CGRect? {
        showsWholePhoto ? nil : face.boundingBox
    }

    private func personColumn(face: PersonInfo.Face, name: String) -> some View {
        VStack(spacing: 8) {
            // 写真全体モードでは box を渡さない（loadFaceAvatar が切り抜かず全体を返す）。
            // 全体は横長のことが多いので、丸ではなく角丸の枠で見せる。
            FaceAvatarImage(refKey: face.refKey,
                            box: showsWholePhoto ? nil : face.boundingBox,
                            maxPixel: Self.columnPixel)
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: showsWholePhoto ? 12 : 60, style: .continuous))
            if !name.isEmpty {
                Text(name).font(.subheadline)
            }
        }
    }

    /// 顔 ⇄ 写真全体の切り替えボタン。
    private var wholePhotoToggle: some View {
        Button {
            showsWholePhoto.toggle()
        } label: {
            Label(showsWholePhoto ? L("Show face only") : L("Show whole photo"),
                  systemImage: showsWholePhoto ? "person.crop.square" : "photo")
                .font(.footnote)
        }
        .buttonStyle(.bordered)
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
            // 顔スキャンが進むと候補は増える。閉じて開き直さずに次を探せるようにする。
            Button(L("Find more")) { Task { await load() } }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            if peopleEngine.isScanning {
                Text(L("Still scanning photos — more will appear as it progresses."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
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
            case .splitCluster(let clusterID, _, _, _, let groupB, _):
                await peopleEngine.answerSplitCluster(clusterID: clusterID,
                                                      groupBFaceIDs: groupB, same: yes)
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
