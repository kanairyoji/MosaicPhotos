import Foundation
import MosaicSupport
import PerceptionCore

// MARK: - モデル更新の影の世代（ADR-186）
//
// 顔の索引は「クラスタ」という全体構造を持つので、モデルが変わっても行ごとに版を付けて
// 1 つの台帳に混ぜることはできない（新旧の埋め込みは同じ空間に無い）。そこで:
//   - 同梱モデルの ID が現行世代と違えば、新モデル用の**別コンテナ**（`Faces-<id>`）を作り、
//     スキャンはそちらへ（`FaceTagger` の store を差し替える）。表示・編集は旧世代のまま。
//   - 影の世代の網羅（候補に対するスキャン済み）が閾値（90%）に達したら、名前を写真の重なりで移し
//     （既存の持ち越し・ADR-51/169）、ピープルグループを名前で作り直し、現行世代を差し替える。
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

    /// 影の世代を現行世代にする（名前・グループを移す・旧世代は残す）。
    func promoteShadow() async {
        guard let shadow = shadowStore, let modelID = faceProvider?.modelID else { return }
        let old = store
        // 1. 名前: 旧世代の命名済みクラスタ（メンバー写真つき）を新世代へ写真の重なりで移す。
        //    足りない分（まだスキャンされていない写真の人物）は持ち越しファイルに残し、
        //    以後のスキャン完了ごとに段階的に戻す（既存の仕組み）。
        let named = await old.namedClusterEntries()
        let remaining = await shadow.reapplyNames(named)
        saveCarryover(remaining.isEmpty ? nil
                      : NameCarryover(savedAt: Date(), entries: remaining.map { .init(name: $0.name, memberRefKeys: $0.memberRefKeys) }))
        // 2. グループ: メンバーは clusterID なので世代をまたげない。名前で新世代の人物へ結び直す。
        //    名前の無いメンバーは落ちる（グループは名前付きの人物で作るのが普通）。
        let oldGroups = await old.allPeopleGroupRecords()
        if !oldGroups.isEmpty {
            let oldNames = await old.allClusters().reduce(into: [Int: String]()) { acc, c in
                if let n = c.name, !n.isEmpty { acc[c.clusterID] = n }
            }
            let newByName = await shadow.allClusters().reduce(into: [String: Int]()) { acc, c in
                if let n = c.name, !n.isEmpty, acc[n] == nil { acc[n] = c.clusterID }
            }
            for g in oldGroups {
                let members = g.memberClusterIDs.compactMap { oldNames[$0] }.compactMap { newByName[$0] }
                if !members.isEmpty { _ = await shadow.createPeopleGroup(name: g.name, memberClusterIDs: members) }
            }
        }
        // 3. 切り替え（旧コンテナは消さない）。
        store = shadow
        shadowStore = nil
        tagger = FaceTagger(store: shadow, provider: faceProvider)
        UserDefaults.standard.set(modelID, forKey: Self.activeFaceModelKey)
        UserDefaults.standard.set(effectiveScanVersion, forKey: Self.faceScanVersionKey)
        Diagnostics.mark("faces: promoted shadow generation → \(modelID) (names \(named.count - remaining.count)/\(named.count) carried, groups \(oldGroups.count))")
        // clusterID が変わった＝外部が持つ人物参照（共有の sourceKey 等）は当てにならない。
        await onPersonIdentitiesInvalidated?()
        await loadPeople()
    }
}
