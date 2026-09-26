import Foundation
import MosaicSupport
import PerceptionCore

// MARK: - モデル更新の影の世代（ADR-186）
//
// 顔の索引は「クラスタ」という全体構造を持つので、モデルが変わっても行ごとに版を付けて
// 1 つの台帳に混ぜることはできない（新旧の埋め込みは同じ空間に無い）。そこで:
//   - 同梱モデルの ID が現行世代と違えば、新モデル用の**別コンテナ**（`Faces-<id>`）を作り、
//     スキャンはそちらへ（`FaceTagger` の store を差し替える）。表示・編集は旧世代のまま。
//   - 影の世代の網羅（候補に対するスキャン済み）が閾値（90%）に達したら、表明（名前・束ね・
//     ピープルグループの所属）を写真の重なりで移し（既存の持ち越し・ADR-51/169/232）、
//     現行世代を差し替える。
//   - 旧世代のコンテナは**消さない**（1 リリース残す）。切り替えは診断ログに残す。
// 持ち越せないもの: 埋め込みで記録した修正（`FaceCorrection` の負例・確認）。空間が違うので意味を
// 持たない。旧コンテナに残るが新世代には効かない（同じ誤りが再び出ることがある）。

extension PeopleEngine {

    /// 影の世代を育てている最中か（AI 解析画面の表示用）。
    public var isMigratingFaceModel: Bool { shadowStore != nil }

    /// 影の世代の進み具合（候補に対するスキャン済み）。影が無ければ nil。
    public func faceModelMigrationProgress(candidateRefKeys: [String]) async -> (scanned: Int, total: Int)? {
        guard let shadowStore else { return nil }
        let pending = await shadowStore.pendingCount(candidateRefKeys: candidateRefKeys)
        return (candidateRefKeys.count - pending, candidateRefKeys.count)
    }

    /// 影の世代の網羅が閾値に達していれば、現行世代へ切り替える。
    /// - Returns: 切り替えたか。
    @discardableResult
    func promoteShadowIfReady(candidateCount: Int) async -> Bool {
        guard let shadow = shadowStore, candidateCount > 0 else { return false }
        let scanned = await shadow.scannedCount()
        guard Double(scanned) >= Double(candidateCount) * Self.shadowPromotionCoverage else {
            Diagnostics.mark("faces: shadow generation \(scanned)/\(candidateCount) — not yet (\(Int(Self.shadowPromotionCoverage * 100))% needed)")
            return false
        }
        await promoteShadow()
        return true
    }

    /// 影の世代を現行世代にする（表明を移す・旧世代は残す）。
    func promoteShadow() async {
        guard let shadow = shadowStore, let modelID = faceProvider?.modelID else { return }
        let old = store
        // 1. グループの器を先に作る（**id を引き継いだ空の行**）。メンバーは次の手で入る。
        //    ⚠️ 器が無いと、持ち越しがメンバーを書き込む先を失う（＝家族グループが消える）。
        let oldGroups = await old.allPeopleGroupRecords()
        for g in oldGroups {
            await shadow.importPeopleGroupShell(id: g.id, name: g.name, createdAt: g.createdAt)
        }
        // 2. 表明（名前・束ね・グループ所属）を新世代へ**写真の重なりで**移す（ADR-232）。
        //    足りない分（まだスキャンされていない写真の人物）は持ち越しファイルに残し、
        //    以後のスキャン完了ごとに段階的に戻す（既存の仕組み）。
        //    ⚠️ 以前は名前だけを移し、グループは**名前で結び直して**いた——無名のメンバーは
        //    落ち、同名の別人は混ざった。写真の重なりは名前を要らなくする。
        let asserted = await old.assertedClusterEntries()
        let remaining = await shadow.reapplyAssertions(asserted)
        // ⚠️ **ディスクに残っている戻り待ちを踏み潰さない**（レビュー指摘・ADR-232）。
        // 戻り待ちは「どちらのストアにも居ない人」（写真がまだ再スキャンされていない）なので、
        // `asserted` には入らない。ここで上書きすると——特に空なら**ファイルごと消える**ので
        // ——版上げの途中で新しいモデルが来た瞬間に、戻り待ちの名前・束ね・グループ所属が
        // 全部消えて二度と戻らない。`snapshotAssertionsForRescan` と同じ重ね方を通す。
        let carried = CarriedAssertion.merged(snapshot: remaining,
                                              pending: loadCarryover()?.entries ?? [],
                                              limit: Self.maxCarryoverEntries)
        saveCarryover(carried.isEmpty ? nil : NameCarryover(savedAt: Date(), entries: carried))
        // 3. 切り替え（旧コンテナは消さない）。
        // ⚠️ **控えを捨ててから差し替える**（レビュー指摘）。`undoStack` は `FaceStore` が
        // メモリに持つので、差し替えると空になるのに **`undoLabel` は published のまま残る**
        // ——「戻す」の行が出ているのに押しても何も起きない。
        // 再クラスタ（`rebuildClustersIfNeeded`）と `reset` は同じ理由で既にそうしている。
        await clearUndoHistory()
        store = shadow
        shadowStore = nil
        tagger = FaceTagger(store: shadow, provider: faceProvider)
        UserDefaults.standard.set(modelID, forKey: Self.activeFaceModelKey)
        UserDefaults.standard.set(effectiveScanVersion, forKey: Self.faceScanVersionKey)
        // ⚠️ **メンバーが入ったグループの数**まで出す（F7 の確認）。器の数だけ出していると、
        // 全部空のまま切り替わっても「groups 3」と見えて成功と読めてしまう。
        let filledGroups = await shadow.allPeopleGroupRecords()
            .filter { !$0.memberClusterIDs.isEmpty }.count
        Diagnostics.mark("faces: promoted shadow generation → \(modelID) "
                         + "(assertions \(asserted.count - remaining.count)/\(asserted.count) carried, "
                         + "\(carried.count) pending, "
                         + "groups \(filledGroups)/\(oldGroups.count) with members)")
        // clusterID が変わった＝外部が持つ人物参照（共有の sourceKey 等）は当てにならない。
        await onPersonIdentitiesInvalidated?()
        await loadPeople()
    }
}
