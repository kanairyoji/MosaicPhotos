import PerceptionCore
import CoreGraphics
import Foundation
import MosaicSupport
import SwiftData

/// `FaceStore` の 取り出し・2 階層束ね・名前解決 関連（extension 分割・ADR）。
extension FaceStore {
    // MARK: - 「人物」の判定（UI とレビューで必ず同じ土俵を使う）

    /// ピープルに出る人物とみなすクラスタ（**実際の写真枚数**が `minFaces` 以上）。
    ///
    /// ⚠️ `PersonCluster.count` は**重心に寄与した顔数**で、第2パス（ADR-66・membership のみ）で
    /// 付いた顔を含まない。実機では全顔の約 48% が品質フロア未満＝第2パス扱いのため、
    /// 「UI には人物として出るが `count` は 1〜2」というクラスタが大多数になる。
    /// レビュー側が `count` で母数を絞っていたため、**UI の 370 人のうち大半が統合候補に
    /// 上がらない**という実障害になっていた（ADR-68 追補3）。判定はここに一本化する。
    func peopleEligibleClusters(minFaces: Int) -> [PersonCluster] {
        var photosPerCluster: [Int: Set<String>] = [:]
        // 必要なのは clusterID と refKey だけ。射影して `embedding`（約1KB/顔）を読まない（ADR-96）。
        var query = FetchDescriptor<DetectedFace>()
        query.propertiesToFetch = [\.clusterID, \.refKey]
        for f in (countedFetchOptional(query)) ?? [] where f.clusterID >= 0 {
            photosPerCluster[f.clusterID, default: []].insert(f.refKey)
        }
        return allClusters().filter { (photosPerCluster[$0.clusterID]?.count ?? 0) >= minFaces }
    }

    // MARK: - 取り出し（表示用）

    /// 「人物」とみなすクラスタ（メンバー数 `minFaces` 以上）を多い順に返す。
    /// 代表写真（cover）の優先順位: ユーザーが選んだ顔（`coverFaceID`・現存するもの）
    /// → **お気に入りマークの写真**の顔（`favoriteRefKeys`）→ 認識した写真の先頭。
    ///
    /// - Parameter includeMembers: `PersonInfo.memberRefKeys` を積むか（既定 true）。
    ///   **一覧表示（`PeopleEngine.people`）は false で呼ぶ**。`count` は常に正しく、違いは
    ///   メンバーキー配列を持ち歩くかどうかだけ。数百人×各数十〜数千キーを MainActor へ載せると、
    ///   (1) 発行のたびに万単位の String が往復し、(2) `PersonAlbumView.init` が再評価のたびに
    ///   全キーを `PhotoRef.decode` し直す（SwiftUI は init を何度でも呼ぶ）ため、実機で
    ///   フォアグラウンド 600〜1000ms のハングが人物リスト発行 1 回につき 1 回出ていた
    ///   （diagnostics-38 で 105 回・ADR-95）。メンバーが要る画面は `memberRefKeys(forPerson:)` で
    ///   必要なときだけ取りに来る。
    func peopleClusters(minFaces: Int = 3, favoriteRefKeys: Set<String> = [],
                        includeMembers: Bool = true) -> [PersonInfo] {
        // ⚠️ 全顔を**1 回の射影クエリ**で取り、クラスタ ID でメモリ上に束ねる（ADR-96）。
        //    以前はクラスタごとに `faces(inCluster:)` を呼んでいた＝936 クラスタなら 936 回の
        //    fetch ＋ 全 @Model の materialize。`DetectedFace.embedding` は 1 顔あたり約 1KB
        //    （512 次元）で、表示には**一切使わない**のに毎回読み出していた。
        //    実機 diagnostics-42 では `people.load.clusters` が 725〜3585ms かかり、
        //    同じ長さのフォアグラウンドハングと 1 対 1 に対応していた（671/725・2028/2188・896/997）。
        //    ADR-88 が `memberRefKeys(inCluster:)` に入れた射影を、人物一覧の本体にも適用する。
        var facesByCluster: [Int: [DetectedFace]] = [:]
        var faceQuery = FetchDescriptor<DetectedFace>()
        faceQuery.propertiesToFetch = [\.faceID, \.refKey, \.clusterID,
                                       \.bx, \.by, \.bw, \.bh, \.quality, \.hasSmile]
        for f in (countedFetchOptional(faceQuery)) ?? [] where f.clusterID >= 0 {
            facesByCluster[f.clusterID, default: []].append(f)
        }
        // 2 階層（ADR-61）: personGroupID が同じクラスタを 1 人物に束ねる（子供の時期クラスタ）。
        // nil のクラスタは従来どおり単独（1 クラスタ=1 人物）＝全 nil なら旧挙動と一致。
        var groups: [String: [PersonCluster]] = [:]
        var order: [String] = []
        for c in allClusters() {
            let key = c.personGroupID.map { "g\($0)" } ?? "c\(c.clusterID)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(c)
        }
        var result: [PersonInfo] = []
        for key in order {
            let clustersInGroup = groups[key]!
            // 束ね内の全クラスタの顔を集約し、写真キーを重複排除。
            var allFaces: [DetectedFace] = []
            for c in clustersInGroup { allFaces += facesByCluster[c.clusterID] ?? [] }
            var seen = Set<String>()
            var members: [String] = []
            for f in allFaces where seen.insert(f.refKey).inserted { members.append(f.refKey) }
            guard members.count >= minFaces else { continue }
            // 主クラスタ: **名前つきを最優先**し、同条件ならメンバー最多 → clusterID 昇順。
            // ⚠️ 以前は `first { 名前つき }` だったが、`allClusters()` の取得順は不定なので
            //    名前つきが複数あると**毎回違う名前が表示され**、ユーザーには「付けた名前が消えた」
            //    ように見えた（実フィードバック・ADR-94）。決定的な順序で選ぶ。
            let primary = clustersInGroup.sorted { a, b in
                let an = a.name?.isEmpty == false, bn = b.name?.isEmpty == false
                if an != bn { return an }                    // 名前つきが先
                if a.count != b.count { return a.count > b.count }   // 次に写真の多い方
                return a.clusterID < b.clusterID             // 最後は ID で決定的に
            }[0]
            let primaryFaces = facesByCluster[primary.clusterID] ?? []
            // 自動選択は「笑顔＋高品質＋大きく写っている」顔を優先（face-info-expansion 優先度 5）。
            let cover = primary.coverFaceID.flatMap { fid in allFaces.first { $0.faceID == fid } }
                ?? Self.bestCoverFace(allFaces.filter { favoriteRefKeys.contains($0.refKey) })
                ?? Self.bestCoverFace(primaryFaces)
                ?? Self.bestCoverFace(allFaces)
            let box = cover.map { CGRect(x: $0.bx, y: $0.by, width: $0.bw, height: $0.bh) }
            result.append(PersonInfo(
                clusterID: primary.clusterID, name: primary.name, count: members.count,
                coverRefKey: cover?.refKey, coverBoundingBox: box,
                memberRefKeys: includeMembers ? members : [],
                isGrouped: clustersInGroup.count > 1))
        }
        // 通し番号は**並べ替え後**に振る（ADR-68）。
        // 並び（実フィードバック）: **名前つきが先**（ユーザーが関心を示した人）→ それぞれの中は
        // 写真数降順 → 同数は clusterID 昇順。
        // ⚠️ 完全に決定的にする: Swift の sort は非安定で、同数クラスタ（3 枚組が数百件）だけの
        //    比較だと実行ごとに順序が揺れ、リロードのたびに一覧が入れ替わって見える。
        var ordered = result.sorted { a, b in
            let an = a.name?.isEmpty == false, bn = b.name?.isEmpty == false
            if an != bn { return an }                            // 名前つきが先
            if a.count != b.count { return a.count > b.count }   // 次に写真の多い方
            return a.clusterID < b.clusterID                     // 最後は ID で決定的に
        }
        for i in ordered.indices { ordered[i].displayIndex = i + 1 }
        return ordered
    }

    // MARK: - 2 階層の人物束ね（ADR-61）

    /// 複数クラスタを 1 人物に束ねる（**融合しない**＝各クラスタの純度を保ったまま personGroupID を
    /// 揃える）。ユーザーが「同じ子（成長で分裂）」と指定したときに呼ぶ。既存の束ねグループも巻き込む
    /// （推移的）。名前・代表は主クラスタが持つ（peopleClusters が解決）。
    /// 束ねようとしている集合に**別々の名前**が付いているか（ADR-94）。
    /// 付いていれば UI がどちらを残すかユーザーに尋ねる（＋「やめる」を選べる）。
    /// - Returns: 重複を除いた名前の一覧（0〜1 件なら確認不要）。
    func conflictingNames(in clusterIDs: [Int]) -> [String] {
        var names: [String] = []
        for id in clusterIDs {
            // 既存グループの他メンバーも巻き込まれるので、その名前も見る。
            for linked in linkedClusterIDs(primary: id) {
                if let n = cluster(linked)?.name, !n.isEmpty, !names.contains(n) { names.append(n) }
            }
        }
        return names
    }

    /// 束ねた全クラスタの名前を `name` に揃える（ADR-94）。
    /// ユーザーが「どちらの名前を残すか」を選んだ後に呼ぶ。揃えておかないと、主クラスタの
    /// 選び方が変わったときに表示名が入れ替わって見える。
    func unifyName(_ name: String, in clusterIDs: [Int]) {
        var targets = Set<Int>()
        for id in clusterIDs { targets.formUnion(linkedClusterIDs(primary: id)) }
        for c in allClusters() where targets.contains(c.clusterID) { c.name = name }
        try? modelContext.save()
    }

    func linkClusters(_ clusterIDs: [Int]) {
        let picked = clusterIDs.compactMap { cluster($0) }
        guard picked.count >= 2 else { return }
        let existingGroups = Set(picked.compactMap { $0.personGroupID })
        let gid = existingGroups.min() ?? (picked.map(\.clusterID).min() ?? picked[0].clusterID)
        var targets = Set(picked.map(\.clusterID))
        // 既存グループの他メンバーも同じ gid に寄せる（複数回の束ねで分断しない）。
        if !existingGroups.isEmpty {
            for c in allClusters() where c.personGroupID.map(existingGroups.contains) == true {
                targets.insert(c.clusterID)
            }
        }
        for c in allClusters() where targets.contains(c.clusterID) { c.personGroupID = gid }
        try? modelContext.save()
        clusteringCache = nil
    }

    /// 束ねから 1 クラスタを外す（別人だった等）。personGroupID を nil に戻す。
    func unlinkCluster(_ clusterID: Int) {
        cluster(clusterID)?.personGroupID = nil
        try? modelContext.save()
        clusteringCache = nil
    }

    /// ある人物（主クラスタ ID で指定）に束ねられた全クラスタ ID（自分含む）。
    func linkedClusterIDs(primary clusterID: Int) -> [Int] {
        guard let c = cluster(clusterID) else { return [clusterID] }
        guard let gid = c.personGroupID else { return [clusterID] }
        return allClusters().filter { $0.personGroupID == gid }.map(\.clusterID)
    }

    /// 笑顔の実測（refKey → 笑顔の顔数・スキャン済みの写真のみ）。
    /// AI アルバムの「笑っている写真」条件（`.smiling`・S10・ADR-103）に使う。
    /// クラスタ未割り当ての顔も数える（笑顔かどうかに人物の同定は要らない）。
    func smilingFaceCounts() -> [String: Int] {
        var d = FetchDescriptor<DetectedFace>(predicate: #Predicate { $0.hasSmile == true })
        d.propertiesToFetch = [\.refKey]
        var out: [String: Int] = [:]
        for f in (countedFetchOptional(d)) ?? [] { out[f.refKey, default: 0] += 1 }
        // 「スキャン済みだが笑顔ゼロ」も 0 として載せる（証拠主義: キーの有無＝スキャン済みか）。
        var scanned = FetchDescriptor<ScannedPhoto>()
        scanned.propertiesToFetch = [\.refKey]
        for m in (countedFetchOptional(scanned)) ?? [] where out[m.refKey] == nil {
            out[m.refKey] = 0
        }
        return out
    }

    /// 1 人物（束ねていれば全時期クラスタ）のメンバー写真キー。順序・重複排除は
    /// `peopleClusters(includeMembers: true)` と一致させる（人物アルバムの並びが変わらないように）。
    /// 一覧発行から切り離して**開いた画面だけが**取りに来るための入口（ADR-95）。
    func memberRefKeys(forPerson clusterID: Int) -> [String] {
        var seen = Set<String>()
        var members: [String] = []
        for id in linkedClusterIDs(primary: clusterID) {
            for f in faces(inCluster: id) where seen.insert(f.refKey).inserted {
                members.append(f.refKey)
            }
        }
        return members
    }

    /// この写真に写っている「人物」がちょうど 1 人ならそのクラスタ ID を返す（束ねは 1 人として畳む）。
    ///
    /// ⚠️ 人物アルバム以外（AI アルバム・場所・全写真）で「この人は XX ではない」を出すための判定。
    /// **1 人しか写っていない写真に限る**のは、複数人の写真では「どの人を直すのか」が
    /// メニューの文言だけでは決まらないため（顔の管理／人物アルバム側でやる）。
    func solePersonClusterID(refKey: String) -> Int? {
        var clusterIDs = Set<Int>()
        for f in faces(inPhoto: refKey) where f.clusterID >= 0 { clusterIDs.insert(f.clusterID) }
        guard !clusterIDs.isEmpty else { return nil }
        // 束ねられたクラスタ（成長で分かれた同一人物）は 1 人として数える。
        var groups = Set<Int>()
        for id in clusterIDs { groups.insert(linkedClusterIDs(primary: id).min() ?? id) }
        guard groups.count == 1 else { return nil }
        return clusterIDs.min()
    }

    /// この写真に写っている**指定クラスタの**顔矩形（Vision 正規化・原点左下）。
    /// 人物アルバムで「どの顔をこの人物として認識したか」をチェックする用途なので、
    /// 同じ写真の複数の顔が同一クラスタに入っていても（混入の疑い）、
    /// **重心に最も近い 1 顔だけ**を返す（全部に枠が付くとどれがこの人物か
    /// 分からず目的を果たせない＝実フィードバック）。
    func faceBoxes(refKey: String, clusterID: Int) -> [CGRect] {
        // 2 階層束ね（ADR-61）: 束ねた人物は全時期クラスタの顔をこの人物として扱う。
        let groupIDs = Set(linkedClusterIDs(primary: clusterID))
        let members = faces(inPhoto: refKey).filter { groupIDs.contains($0.clusterID) }
        guard members.count > 1 else {
            return members.map { CGRect(x: $0.bx, y: $0.by, width: $0.bw, height: $0.bh) }
        }
        // 束ねグループの重心（属するクラスタ重心の平均）に最も近い 1 顔を選ぶ。
        var centroids: [[Float]] = []
        for gid in groupIDs {
            if let c = cluster(gid), let sum = ClipMath.decodeHalf(c.sum) {
                centroids.append(FaceClustering.normalized(sum))
            }
        }
        var best: (face: DetectedFace, sim: Float)?
        for f in members {
            guard let v = ClipMath.decodeHalf(f.embedding) else { continue }
            let nv = FaceClustering.normalized(v)
            let sim = centroids.map { FaceClustering.dot(nv, $0) }.max() ?? -1
            if best == nil || sim > best!.sim { best = (f, sim) }
        }
        let chosen = best?.face ?? members[0]
        return [CGRect(x: chosen.bx, y: chosen.by, width: chosen.bw, height: chosen.bh)]
    }

    /// クラスタの顔候補（写真ごとに 1 つ・代表写真ピッカー用）。
    func facesForCluster(clusterID: Int) -> [PersonInfo.Face] {
        var seen = Set<String>()
        var out: [PersonInfo.Face] = []
        for f in faces(inCluster: clusterID) where seen.insert(f.refKey).inserted {
            out.append(PersonInfo.Face(
                faceID: f.faceID, refKey: f.refKey,
                boundingBox: CGRect(x: f.bx, y: f.by, width: f.bw, height: f.bh)))
        }
        return out
    }

    /// clusterID → その人物の表示名（2 階層束ねを反映＝サブクラスタも主クラスタの名前）。
    /// 人物とみなす閾値 `minFaces` は**束ねグループの合計写真数**で判定する。未命名は "Person N"。
    /// 検索・名前表示が束ねた人物を 1 人として扱うための共通解決（ADR-61）。
    func personNameByCluster(minFaces: Int) -> [Int: String] {
        var groups: [String: [PersonCluster]] = [:]
        for c in allClusters() {
            let key = c.personGroupID.map { "g\($0)" } ?? "c\(c.clusterID)"
            groups[key, default: []].append(c)
        }
        // ⚠️ クラスタごとに引かない（規模退行テストが検出）。ここは
        // `peopleNames(refKey:)` から**写真を開くたび**に呼ばれるので、人物数に比例させると
        // 「顔スキャンが進むほど写真が開かなくなる」——実測で 40 人 42 回 / 160 人 162 回だった。
        // 必要なのは「グループごとの写真数（minFaces の足切り）」だけなので、
        // 射影クエリ 1 回で clusterID → refKey を取り、束ねはメモリで行う。
        let refKeysByCluster = memberRefKeysByCluster()
        var out: [Int: String] = [:]
        for (_, cs) in groups {
            var seen = Set<String>()
            for c in cs { seen.formUnion(refKeysByCluster[c.clusterID] ?? []) }
            guard seen.count >= minFaces else { continue }
            let primary = cs.first { $0.name?.isEmpty == false }
                ?? cs.max { $0.count < $1.count } ?? cs[0]
            let name = primary.name ?? "Person \(primary.clusterID + 1)"
            for c in cs { out[c.clusterID] = name }
        }
        return out
    }

    /// 全スキャン済み写真の refKey → 人物表示名（自動アルバム生成の people 付与用）。
    /// 「人物」とみなせるクラスタ（minFaces 以上）のみ。未命名は "Person N"。2 階層束ね反映。
    func peopleNamesByRefKey(minFaces: Int) -> [String: [String]] {
        let nameByCluster = personNameByCluster(minFaces: minFaces)
        guard !nameByCluster.isEmpty else { return [:] }
        let faces = (countedFetchOptional(FetchDescriptor<DetectedFace>())) ?? []
        var out: [String: [String]] = [:]
        for f in faces {
            guard let name = nameByCluster[f.clusterID] else { continue }
            if out[f.refKey]?.contains(name) != true {
                out[f.refKey, default: []].append(name)
            }
        }
        return out
    }

    /// この写真に写っている「人物」の表示名（フル画像ビューの People 表示用）。2 階層束ね反映
    /// （束ねた人物は名前で重複排除＝サブクラスタが同じ写真に複数あっても 1 回）。
    func peopleNames(refKey: String, minFaces: Int) -> [String] {
        let nameByCluster = personNameByCluster(minFaces: minFaces)
        var out: [String] = []
        var seen = Set<String>()
        for f in faces(inPhoto: refKey) {
            guard let name = nameByCluster[f.clusterID], seen.insert(name).inserted else { continue }
            out.append(name)
        }
        return out
    }

    /// 代表写真（cover）を指定した顔に設定する。
    ///
    /// ⚠️ **代表写真を選ぶ＝「この人はこの顔」という表明**（ADR-130・ユーザー提案）。
    /// 見た目の設定に留めず、確認顔（アンカー）として記録する——アンカーは再クラスタで
    /// 動かない種になるので、この人物が別人に乗っ取られたり追い出されたりしなくなる。
    func setCover(clusterID: Int, faceID: String) {
        guard let c = cluster(clusterID) else { return }
        c.coverFaceID = faceID
        confirmIdentity(faceID: faceID, clusterID: clusterID)
        try? modelContext.save()
    }

    /// この顔をこの人物の「確認済み」（アンカー）にする。既に確認済みなら何もしない。
    /// 正例として `FaceCorrection` にも残す（ADR-46・再スキャンやモデル更新を跨いで効く）。
    func confirmIdentity(faceID: String, clusterID: Int) {
        guard let face = face(byID: faceID), face.confirmedAt == nil,
              face.clusterID == clusterID else { return }
        if let vec = ClipMath.decodeHalf(face.embedding),
           let c = cluster(clusterID), let sum = ClipMath.decodeHalf(c.sum) {
            let sim = FaceClustering.dot(FaceClustering.normalized(vec),
                                         FaceClustering.normalized(sum))
            recordCorrection(kind: "confirm", faceEmbedding: face.embedding,
                             wrongEmbedding: nil, similarity: sim)
        }
        face.confirmedAt = Date()
    }

}
