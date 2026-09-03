import Foundation
import MosaicSupport
import PerceptionCore

// MARK: - 人物の編集（改名・束ね・統合・付け替え）
//
// ユーザーの操作で人物の構成を変える窓口。実体は `FaceStore+Edit.swift`（永続化と重心の演算）で、
// ここは **控えを取る（取り消しのため）→ 実体を呼ぶ → 一覧を描き直す** の段取りだけを持つ。
//
// ⚠️ 分けた理由: `PeopleEngine` は 780 行あり、一覧・スキャン・編集・取り消し・調査が同居して
// いた。編集は「どの操作の前に何を控えるか」が要点で、まとまっていないと抜けに気づけない
// （実際に、統合がピープルグループの参照を付け替えていなかった＝ADR-170）。
// 振る舞いは変えていない（純粋な分割）。

extension PeopleEngine {

    /// クラスタに名前を付ける／消す。
    public func rename(clusterID: Int, name: String?) async {
        Diagnostics.breadcrumb("people.rename cluster=\(clusterID)")
        await store.rename(clusterID: clusterID, name: name)
        await loadPeople()
    }

    /// 人物 src を人物 dst に統合する（同一人物が別々に認識されたときの修正）。
    /// src の顔は全て dst へ移り、src は消える。名前・代表写真は dst を優先。
    /// 2 階層束ね（ADR-61）: 複数の人物を「同じ人（子供の成長で分裂）」として束ねる。
    /// **融合しない**＝各クラスタの純度と時期の分かれを保ったまま 1 人物として表示・検索する。
    /// 後で `unlinkPerson` で解除できる。
    public func linkPeople(_ clusterIDs: [Int]) async {
        await store.linkClusters(clusterIDs)
        await loadPeople()
    }

    /// 束ねる前に、**別々の名前**が付いていないか調べる（ADR-94）。
    /// 2 件以上返ったら UI が「どちらの名前を残すか（＋やめる）」を尋ねる。
    public func conflictingNames(_ clusterIDs: [Int]) async -> [String] {
        await store.conflictingNames(in: clusterIDs)
    }

    /// 名前を選んでから束ねる（ADR-94）。選んだ名前で全クラスタを揃えてから束ねるので、
    /// 主クラスタの選び方に関わらず表示名が安定する。
    public func linkPeople(_ clusterIDs: [Int], keepingName name: String) async {
        await store.unifyName(name, in: clusterIDs)
        await store.linkClusters(clusterIDs)
        await loadPeople()
    }

    /// 束ねから 1 クラスタを外す（別人だった等）。
    public func unlinkPerson(clusterID: Int) async {
        await store.unlinkCluster(clusterID)
        await loadPeople()
    }

    /// この人物の束ねを全解除する（束ねられた全クラスタを単独に戻す）。
    public func ungroupPerson(clusterID: Int) async {
        Diagnostics.breadcrumb("people.ungroupPerson \(clusterID)")
        for id in await store.linkedClusterIDs(primary: clusterID) {
            await store.unlinkCluster(id)
        }
        await loadPeople()
    }

    /// 統合の結果。**拒否される**ことがある（ユーザーが既に別人と表明している／
    /// 同じ写真に一緒に写っている）ので、呼び出し側は理由を出せるようにする。
    public enum PersonMergeResult: Sendable, Equatable {
        case merged
        /// 別々の名前が付いている＝ユーザーが「別人」と表明済み。
        case rejectedDifferentNames
        /// 同じ写真に一緒に写っている＝同一人物ではあり得ない。
        case rejectedSamePhoto
    }

    @discardableResult
    public func mergePerson(from srcClusterID: Int, into dstClusterID: Int) async -> PersonMergeResult {
        Diagnostics.breadcrumb("people.mergePerson \(srcClusterID)→\(dstClusterID)")
        await store.beginUndo(label: "\(label(srcClusterID)) を \(label(dstClusterID)) に統合",
                              clusterIDs: [srcClusterID, dstClusterID])
        // ⚠️ ユーザーが選んだ統合なので、拒否されても「別人」とは学習しない（ADR-146）。
        let rejection = await store.mergeClusters(from: srcClusterID, into: dstClusterID,
                                                  recordNotSameOnConflict: false)
        await refreshUndoLabel()
        await loadPeople()
        switch rejection {
        case .none: return .merged
        case .differentNames: return .rejectedDifferentNames
        case .samePhotoConflict: return .rejectedSamePhoto
        }
    }

    /// 代表写真の選択候補（クラスタ内の顔・写真ごと）。
    public func coverCandidates(clusterID: Int) async -> [PersonInfo.Face] {
        await store.facesForCluster(clusterID: clusterID)
    }

    /// 代表写真（トップに出す顔）を選ぶ。
    public func setCover(clusterID: Int, faceID: String) async {
        await store.setCover(clusterID: clusterID, faceID: faceID)
        await loadPeople()
    }

    /// 顔を別の人物へ付け替える（「この人は別の人」）。`toClusterID` が nil なら新規人物。
    public func reassignFace(faceID: String, toClusterID: Int?) async {
        // ⚠️ 足あとは**段ごと**に置く。1 つだけだと「付け替えのどこで落ちたか」が分からない
        // （実機 8/31: `people.reassignFace → new` までしか取れなかった）。
        let target = toClusterID.map(String.init) ?? "new"
        Diagnostics.breadcrumb("people.reassignFace → \(target)")
        await store.beginUndo(
            label: "この顔を " + (toClusterID.map { label($0) } ?? "新しい人物") + " へ移す",
            clusterIDs: toClusterID.map { [$0] } ?? [], faceIDs: [faceID])
        Diagnostics.breadcrumb("people.reassignFace: store → \(target)")
        await store.reassignFace(faceID: faceID, toClusterID: toClusterID)
        Diagnostics.breadcrumb("people.reassignFace: reload")
        await refreshUndoLabel()
        await loadPeople()
        Diagnostics.breadcrumb("people.reassignFace: done")
    }

    /// **この写真はこの人ではない**（写真 1 枚ぶんの顔をまとめて外す）。
    /// 人物アルバムのサムネイル長押し・全画面のメニューから呼ぶ。
    /// - Returns: 外した顔の数（0 なら何もしなかった＝UI は「変化なし」を伝える）。
    /// - Parameter itemID: 表示側の写真 ID（生の localIdentifier / Dropbox パス / refKey のいずれでも可。
    ///   `faceHighlights(forItemID:)` と**同じ規則**で解決する——ここだけ別の解き方をすると、
    ///   「黄枠は出るのに外せない」というちぐはぐが起きる）。
    @discardableResult
    public func removePhoto(itemID: String, from clusterID: Int) async -> Int {
        Diagnostics.breadcrumb("people.removePhoto cluster=\(clusterID)")
        // ⚠️ 控えは**束ねた全クラスタ**で取る。主クラスタだけだと、別の時期クラスタに居る顔を
        // 外したときに戻す先が控えられておらず、取り消しが効かない（ADR-61 の束ね）。
        let linked = await store.linkedClusterIDs(primary: clusterID)
        await store.beginUndo(label: "\(label(clusterID)) からこの写真を外す", clusterIDs: linked)
        for key in Self.refKeyCandidates(for: itemID) {
            let removed = await store.removePhoto(refKey: key, from: clusterID)
            if removed > 0 {
                await refreshUndoLabel()
                await loadPeople()
                return removed
            }
        }
        // ⚠️ **何も起きなかったことを記録する**（実フィードバック「押しても変化がない」）。
        // 0 件のときに無言だと、操作が届いていないのか対象が無いのかログから分からない。
        Diagnostics.mark("people: removePhoto — 対象なし（cluster=\(clusterID) linked=\(linked.count) "
                         + "item=\(itemID.prefix(24))）")
        return 0
    }

    /// **この写真は別の人**（写真 1 枚ぶんの顔をまとめて指定の人物へ移す）。
    /// 人物アルバムのサムネイル長押し・全画面メニューから呼ぶ。`to` が nil なら新しい人物。
    /// 戻り値は移した顔の数（0 = この写真にこの人物の顔が無かった）。
    public func movePhoto(itemID: String, from clusterID: Int, to toClusterID: Int?) async -> Int {
        Diagnostics.breadcrumb("people.movePhoto \(clusterID)→\(toClusterID.map(String.init) ?? "new")")
        // 控えは束ねた全クラスタ＋移動先（`removePhoto` と同じ理由）。
        let linked = await store.linkedClusterIDs(primary: clusterID)
        await store.beginUndo(
            label: "この写真を \(label(clusterID)) から "
                 + (toClusterID.map { label($0) } ?? "新しい人物") + " へ移す",
            clusterIDs: linked + (toClusterID.map { [$0] } ?? []))
        for key in Self.refKeyCandidates(for: itemID) {
            let moved = await store.movePhoto(refKey: key, from: clusterID, to: toClusterID)
            if moved > 0 {
                await refreshUndoLabel()
                await loadPeople()
                return moved
            }
        }
        Diagnostics.mark("people: movePhoto — 対象なし（cluster=\(clusterID) linked=\(linked.count) "
                         + "item=\(itemID.prefix(24))）")
        return 0
    }
}
