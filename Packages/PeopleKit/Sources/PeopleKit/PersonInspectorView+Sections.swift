#if canImport(UIKit)
import AutoAlbumCore
import SwiftUI

// MARK: - 人物を調べる: 画面の各セクション
//
// 本体（`PersonInspectorView.swift`）は状態・読み込み・操作に専念し、**見た目はここ**に置く。
// 1 ファイル 772 行で「何をするか」と「どう見せるか」が同居しており、どちらを読みたいときも
// 全部を読む必要があった（振る舞いは変えていない＝純粋な分割）。

extension PersonInspectorView {

    /// 画面上部に固定する「調査対象の人物」。代表写真・枚数・状態を一目で出す。
    var focusHeader: some View {
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
                // 1〜2 枚の断片をまとめて寄せる（ADR-154）。人物どうしの結合は自動化しない。
                Button(L("Tidy up small groups")) { absorbFragments() }
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

    func settingsSection(_ report: PersonDecisionReport) -> some View {
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

    func statusSection(_ focus: PersonDecisionFocus) -> some View {
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

    func neighborSection(_ report: PersonDecisionReport) -> some View {
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
            if report.neighbors.count >= neighborLimit {
                Button(L("Show more")) {
                    neighborLimit += Self.neighborPageSize
                    if let id = focusClusterID { Task { await reload(clusterID: id) } }
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
    func outlierSection(_ report: PersonDecisionReport) -> some View {
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
                // ⚠️ **List の行の中に LazyVGrid を置かない**（実機 8/31 21:59 のクラッシュ）。
                // SwiftUI の List は UICollectionView 実装で、行の中の遅延グリッドは自分の高さを
                // 決めるたびにレイアウトを無効化する。件数が増える（「さらに表示」で 24→48）と
                // 再計算が収束せず、UIKit 側の assertion で落ちた（スタックは
                // `UpdateCoalescingCollectionView.layoutSubviews` → `_updateVisibleCellsNow` ×7 →
                // `_assertionFailure`）。**行を自分で刻む**——1 行＝HStack で高さが確定するので、
                // 何件並べても再計算のループにならない。
                ForEach(outlierRows(report.outliers), id: \.id) { row in
                    HStack(spacing: 6) {
                        ForEach(row.faces) { face in outlierCell(face) }
                        // 端数の行も列幅を揃える（最後の行だけ大きくならない）。
                        if row.faces.count < Self.outlierColumns {
                            ForEach(0..<(Self.outlierColumns - row.faces.count), id: \.self) { _ in
                                Color.clear.aspectRatio(1, contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                if report.outliers.count >= outlierLimit {
                    Button(L("Show more")) {
                        outlierLimit += Self.outlierPageSize
                        if let id = focusClusterID { Task { await reload(clusterID: id) } }
                    }
                }
            } header: {
                Text(L("Photos that may be someone else"))
            } footer: {
                Text(L("These faces look least like the rest of this person. Orange means the app would not put this face here today. Tap one to move it to the right person."))
            }
        }
    }

    /// 間違い候補 1 件ぶんのセル（型チェックを膨らませないよう切り出す）。
    func outlierCell(_ face: PersonOutlierFace) -> some View {
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
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    /// 1 行ぶんの並び（`id` は先頭の顔＝並びが変わっても対応が付く）。
    func outlierRows(_ faces: [PersonOutlierFace]) -> [OutlierRow] {
        FaceGridRows.chunked(faces, columns: Self.outlierColumns)
            .map { OutlierRow(id: $0.first?.faceID ?? "-", faces: $0) }
    }

    /// 間違い候補が空のときの説明（＝出ない理由）。
    func outlierEmptyText(_ status: PersonOutlierStatus) -> String {
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
    var glossarySection: some View {
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

    func glossary(_ term: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(term).font(.subheadline.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
#endif
