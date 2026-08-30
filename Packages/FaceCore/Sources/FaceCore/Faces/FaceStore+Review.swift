import PerceptionCore
import CoreGraphics
import Foundation
import MosaicSupport
import SwiftData

/// `FaceStore` の 人物レビュー（アクティブラーニング） 関連（extension 分割・ADR）。
extension FaceStore {

    // MARK: - 注目人物（レビューの基準・ADR-123）

    /// 名前が 1 つも無いライブラリで、基準として使う人数の上限（大きい順）。
    static let focusFallbackLimit = 8
    /// A1 の候補対を絞る上限（顔の読み出しを有界にする）。出題は `limit` 件なので上位だけ見れば足りる。
    static let mergePairScanLimit = 120
    /// 一括レビューで顔を読む候補の倍率（共起で落ちる分の余裕）。
    static let candidateOverscan = 3

    /// レビューの**基準にする人物**（＝注目人物）。命名済みを大きい順に返し、
    /// 名前が 1 つも無ければ大きい順に `focusFallbackLimit` 人で代用する。
    ///
    /// ⚠️ 実フィードバック（ADR-123）: 「100 枚単位で名前を付けている人物は数名。数枚しかない
    /// 名前も付けていない人物を基準に検討する必要はない」。基準を絞ることで、候補探索は
    /// 人物数² から「基準数 × 人物数」に、顔の読み出しは全顔から基準＋候補ぶんに落ちる。
    /// 無名の断片は**候補側**には出るので、名前を付けた人へ畳んでいく道は塞がない。
    static func focusClusters(_ clusters: [PersonCluster]) -> [PersonCluster] {
        let named = clusters.filter { $0.name?.isEmpty == false }
        guard named.isEmpty else { return named.sorted { $0.count > $1.count } }
        return Array(clusters.sorted { $0.count > $1.count }.prefix(focusFallbackLimit))
    }

    // MARK: - 人物レビュー（A1/A2・ADR-46）

    /// レビューカードの生成。**判断が割れるケースだけ**を選ぶ（アクティブラーニング）:
    /// - A1 統合サジェスト: 重心類似が「合流の一歩手前」（しきい値−0.10 〜 しきい値）の
    ///   クラスタ対。「別人」と記録済みの対は出さない。
    /// - A2 境界の顔: クラスタ内で重心類似が最も低い（しきい値＋0.10 未満）未確認の顔
    ///   ＝混入している別人が最も出やすい位置。
    /// - Parameter excluding: 出題済み（既定回数見せたが答えられなかった）カード ID。
    ///   同じ質問を繰り返さず、次点の候補で埋める（実フィードバック対応）。
    func reviewItems(minFaces: Int, limit: Int = 30,
                     excluding: Set<String> = []) -> [FaceReviewItem] {
        // ⚠️ 内訳を測る（ADR-142）。実機で 1 枚のカード生成に 7 秒かかっていたが、
        // どの段が重いのかログから分からなかった。段ごとに出す。
        let tCalib = PerfTrace.nowNs()
        let thr = calibratedThreshold()
        PerfTrace.logSpan("people.batchReview.threshold", ms: PerfTrace.msSince(tCalib))
        // UI の人物と同じ土俵で母数を取る（ADR-68 追補3）。
        let tPool = PerfTrace.nowNs()
        let clusters = peopleEligibleClusters(minFaces: minFaces)
        PerfTrace.logSpan("people.batchReview.pool", ms: PerfTrace.msSince(tPool),
                          detail: "clusters=\(clusters.count)")
        guard clusters.count >= 1, !Task.isCancelled else { return [] }

        // 重心と名前は `PersonCluster` の列だけで作れる（**顔は 1 枚も引かない**）。
        var centroid: [Int: [Float]] = [:]
        var name: [Int: String] = [:]
        for c in clusters {
            guard let sum = ClipMath.decodeHalf(c.sum) else { continue }
            centroid[c.clusterID] = FaceClustering.normalized(sum)
            // 未命名は空（UI は名前ラベルを出さない。"Person N" は誰か分からず判断の助けにならない）。
            name[c.clusterID] = (c.name?.isEmpty == false) ? (c.name ?? "") : ""
        }

        // ⚠️ **基準は「注目人物」に絞る**（実フィードバック・ADR-123）。
        // 名前を付けた数名だけが実用上の関心で、数枚しかない無名の断片を基準に据えて
        // 総当たりする価値はない。基準を絞ると候補探索は「人物数²」から「基準数 × 人物数」になり、
        // 顔の読み出しも「全顔」から「基準＋候補の顔」だけになる。
        let focus = Self.focusClusters(clusters)
        let focusIDs = Set(focus.map(\.clusterID))

        // 「別人」と記録済みの対（重心埋め込みで照合＝ID の揺れに強い）。
        let notSameRows = ((countedFetchOptional(FetchDescriptor<FaceCorrection>(
            // 「別人と答えた」対に加え、同一写真で統合できない対も出題から外す（ADR-152）。
            predicate: #Predicate { $0.kind == "notSame" || $0.kind == "samePhotoBlock" }))) ?? [])
            .compactMap {
            row -> ([Float], [Float])? in
            guard (row.profile ?? "facenet") == tuning.name else { return nil }   // 別空間（ADR-70 追補）
            guard let wrong = row.wrongEmbedding,
                  let a = ClipMath.decodeHalf(row.faceEmbedding),
                  let b = ClipMath.decodeHalf(wrong) else { return nil }
            return (FaceClustering.normalized(a), FaceClustering.normalized(b))
        }
        // ⚠️ 対ごとに全記録を走査しない（実機 diagnostics-61: 27.8 秒のハングの犯人）。
        // クラスタごとに「どの記録のどちら側へ一致するか」を先に求めておく（`NotSameIndex`）。
        let notSameIndex = NotSameIndex(rows: notSameRows, centroids: centroid)
        guard !Task.isCancelled else { return [] }

        // A1 の候補対（**片側は必ず基準**）。ここでは重心だけで絞り込む＝顔はまだ読まない。
        // 共起（同一写真）の判定は写真集合が要るので、対を絞ってから読む。
        var mergeCandidates: [(a: Int, b: Int, sim: Float)] = []
        for f in focus {
            guard let ca = centroid[f.clusterID] else { continue }
            for c in clusters where c.clusterID != f.clusterID {
                guard let cb = centroid[c.clusterID] else { continue }
                let sim = FaceClustering.dot(ca, cb)
                guard sim >= tuning.mergeBandFloor(threshold: thr),
                      !notSameIndex.isMarkedNotSame(f.clusterID, c.clusterID) else { continue }
                // 別々の名前が付いた人物どうしは出さない（ユーザーが既に別人と表明済み・追補5）。
                guard !Self.namesConflict(name[f.clusterID], name[c.clusterID]) else { continue }
                mergeCandidates.append((f.clusterID, c.clusterID, sim))
            }
        }
        mergeCandidates.sort { $0.sim > $1.sim }
        // 出題は `limit` 件までなので、候補も上位だけ見れば足りる（顔の読み出しを有界にする）。
        mergeCandidates = Array(mergeCandidates.prefix(Self.mergePairScanLimit))
        guard !Task.isCancelled else { return [] }

        // ここで初めて顔を読む——**基準と、候補に挙がったクラスタだけ**。
        var needed = focusIDs
        for cand in mergeCandidates { needed.insert(cand.a); needed.insert(cand.b) }
        let tFaces = PerfTrace.nowNs()
        let membersByCluster = faceDigests(inClusters: needed)
        PerfTrace.logSpan("people.batchReview.faces", ms: PerfTrace.msSince(tFaces),
                          detail: "clusters=\(needed.count)")

        var coverFace: [Int: PersonInfo.Face] = [:]
        var photoSets: [Int: Set<String>] = [:]
        let coverByCluster = Dictionary(uniqueKeysWithValues: clusters.map { ($0.clusterID, $0.coverFaceID) })
        for (id, members) in membersByCluster {
            photoSets[id] = Set(members.map(\.refKey))
            let pick = coverByCluster[id].flatMap { fid in members.first { $0.faceID == fid } }
                ?? members.max { $0.coverScore < $1.coverScore }
            if let f = pick {
                coverFace[id] = PersonInfo.Face(faceID: f.faceID, refKey: f.refKey,
                                                boundingBox: f.box)
            }
        }

        // A3: 事後監査（ADR-69）＝「この人物、実は 2 人では？」を最優先で尋ねる。
        // 混入は分裂より害が大きい（間違った人のアルバムに他人が混ざる）。基準の人物だけを見る。
        var items: [FaceReviewItem] = auditSplitItems(targets: Array(focus.prefix(Self.boundaryScanLimit)),
                                                      limit: 5, membersByCluster: membersByCluster)
            .filter { !excluding.contains($0.id) }

        // A1: 統合サジェスト（類似度の高い対から）。共起抑制: 同じ写真に一緒に写った対は
        // **別人**（同一人物は 1 枚に 1 回しか写れない）ので提案しない。
        for cand in mergeCandidates {
            guard items.count < limit else { break }
            guard (photoSets[cand.a] ?? []).isDisjoint(with: photoSets[cand.b] ?? []) else { continue }
            guard let fa = coverFace[cand.a], let fb = coverFace[cand.b] else { continue }
            let item = FaceReviewItem.samePerson(
                aClusterID: cand.a, aName: name[cand.a] ?? "", aFace: fa,
                bClusterID: cand.b, bName: name[cand.b] ?? "", bFace: fb,
                similarity: cand.sim)
            if excluding.contains(item.id) { continue }
            items.append(item)
        }

        // A2: 境界の顔（クラスタごとに最大 2・類似が低い順）。**基準の人物だけ**を見る。
        // ⚠️ 以前は「命名済み優先で並べた先頭 60 クラスタ」を走査しており、無名の断片まで
        // 実体（埋め込み込み）で引いていた。基準に絞れば読み出しは数クラスタで済む。
        // ⚠️ 基準が多い人（何百人も名前を付けた場合）でも上限を跨がない。ここは 1 人につき
        // 実体（埋め込み込み）を 1 回引くので、基準の数がそのまま fetch 回数になる。
        for c in focus.prefix(Self.boundaryScanLimit) {
            guard items.count < limit, !Task.isCancelled, let cen = centroid[c.clusterID] else { continue }
            var boundary: [(face: DetectedFace, sim: Float)] = []
            // 品質フロア未満の顔は出題しない（ADR-53 追補）。境界レビューは「最も疑わしい顔」を
            // 選ぶため、旧データに残る誤検出（模様等の偽陽性・低品質）がそのまま最優先で出て
            // 「顔じゃないカード」になる実障害があった。フロア未満は再スキャンで浄化されるまで
            // 表示にも出さない（ユーザーに判断を求める価値がない）。
            for f in faces(inCluster: c.clusterID)
                where f.confirmedAt == nil && f.quality >= Double(Self.qualityFloor) {
                guard let vec = ClipMath.decodeHalf(f.embedding) else { continue }
                let sim = FaceClustering.dot(FaceClustering.normalized(vec), cen)
                if sim < thr + 0.10 { boundary.append((f, sim)) }
            }
            guard let cover = coverFace[c.clusterID] else { continue }
            var perCluster = 0
            for entry in boundary.sorted(by: { $0.sim < $1.sim }) {
                guard items.count < limit, perCluster < 2 else { break }
                // 未命名（Person N）は name=nil ＝ UI が「代表の顔と並べて比較」カードにする
                //（名前を出しても誰か分からず答えられない・実フィードバック）。
                // 境界顔自身が代表と同一（1 枚だけのケース等）は比較にならないので出さない。
                let displayName = (c.name?.isEmpty == false) ? c.name : nil
                if displayName == nil && cover.faceID == entry.face.faceID { continue }
                let item = FaceReviewItem.isThisPerson(
                    face: PersonInfo.Face(faceID: entry.face.faceID, refKey: entry.face.refKey,
                                          boundingBox: CGRect(x: entry.face.bx, y: entry.face.by,
                                                              width: entry.face.bw, height: entry.face.bh)),
                    clusterID: c.clusterID, name: displayName,
                    coverFace: cover,
                    similarity: entry.sim)
                if excluding.contains(item.id) { continue }   // 出題済み → 次点で埋める
                items.append(item)
                perCluster += 1
            }
        }
        return items
    }

    // MARK: - クラスタ事後監査（ADR-69）

    /// 「この人物、実は 2 人では？」を尋ねるカードを作る。
    /// 統合はユーザー確認を経ているが、**確認した時点では材料が足りない**ことがある
    /// （兄弟は数枚では区別できない）。写真が増えて分布が見えてきたら機械側から拾い直す。
    /// ⚠️ **自動分割はしない**（成長データでは誤検出 8% が残るため）。必ずユーザーに尋ねる。
    /// - Parameter targets: 監査する人物（**基準の人物だけ**を渡す・ADR-123）。
    ///   無名の断片まで監査しても答えられる質問にならないうえ、実体（埋め込み込み）の
    ///   読み出しが人物数に比例して増える。
    func auditSplitItems(targets: [PersonCluster], limit: Int = 10,
                         membersByCluster: [Int: [FaceDigest]]? = nil) -> [FaceReviewItem] {
        // ⚠️ クラスタごとに実体を引かない（規模退行テストが検出）。件数の足切りは
        // **射影**で得た束ねで済ませ、埋め込みが要る本体だけを引く（上限は `limit` 件）。
        // 以前は足切りで捨てるクラスタまで実体を引いており、人物 4 倍で fetch が
        // 31 → 103 回に増えていた（＝人物が増えるほどレビュー画面が遅くなる）。
        let memberDigests = membersByCluster
            ?? faceDigests(inClusters: Set(targets.map(\.clusterID)))
        // 「同じ人だ」と答え済みの対は二度と尋ねない。
        let confirmedSame = ((countedFetchOptional(FetchDescriptor<FaceCorrection>(
            predicate: #Predicate { $0.kind == "sameGroup" }))) ?? []).compactMap {
            row -> ([Float], [Float])? in
            guard (row.profile ?? "facenet") == tuning.name else { return nil }   // 別空間（ADR-70 追補）
            guard let wrong = row.wrongEmbedding,
                  let a = ClipMath.decodeHalf(row.faceEmbedding),
                  let b = ClipMath.decodeHalf(wrong) else { return nil }
            return (FaceClustering.normalized(a), FaceClustering.normalized(b))
        }
        func alreadyAnsweredSame(_ a: [Float], _ b: [Float]) -> Bool {
            for (ra, rb) in confirmedSame {
                if (FaceClustering.dot(a, ra) >= 0.9 && FaceClustering.dot(b, rb) >= 0.9)
                    || (FaceClustering.dot(a, rb) >= 0.9 && FaceClustering.dot(b, ra) >= 0.9) {
                    return true
                }
            }
            return false
        }

        var items: [FaceReviewItem] = []
        // 大きいクラスタから見る（混入の影響が大きい）。
        for c in targets.sorted(by: { $0.count > $1.count }) {
            guard items.count < limit, !Task.isCancelled else { break }
            // 足切りは束ね（射影）で判定する＝ここでは引かない。
            guard (memberDigests[c.clusterID]?.count ?? 0) >= tuning.auditConfig.minMembers
            else { continue }
            let members = faces(inCluster: c.clusterID)   // 埋め込みが要るのでここだけ実体
            var vectors: [[Float]] = []
            var keys: [String] = []
            var kept: [DetectedFace] = []
            for f in members {
                guard let v = ClipMath.decodeHalf(f.embedding) else { continue }
                vectors.append(v); keys.append(f.refKey); kept.append(f)
            }
            guard let s = FaceClusterAudit.auditForSplit(embeddings: vectors, photoKeys: keys,
                                                         config: tuning.auditConfig) else { continue }
            let centroidA = FaceClusterAudit.centroid(s.groupA.map { FaceClustering.normalized(vectors[$0]) })
            let centroidB = FaceClusterAudit.centroid(s.groupB.map { FaceClustering.normalized(vectors[$0]) })
            guard !alreadyAnsweredSame(centroidA, centroidB) else { continue }

            // 各群の代表顔（品質＋笑顔＋大きさ）。
            guard let fa = Self.bestCoverFace(s.groupA.map { kept[$0] }),
                  let fb = Self.bestCoverFace(s.groupB.map { kept[$0] }) else { continue }
            items.append(.splitCluster(
                clusterID: c.clusterID,
                name: (c.name?.isEmpty == false) ? c.name : nil,
                faceA: PersonInfo.Face(faceID: fa.faceID, refKey: fa.refKey,
                                       boundingBox: CGRect(x: fa.bx, y: fa.by, width: fa.bw, height: fa.bh)),
                faceB: PersonInfo.Face(faceID: fb.faceID, refKey: fb.refKey,
                                       boundingBox: CGRect(x: fb.bx, y: fb.by, width: fb.bw, height: fb.bh)),
                groupBFaceIDs: s.groupB.map { kept[$0].faceID },
                margin: s.margin))
        }
        return items
    }

    // MARK: - 品質スナップショット（ADR-68）

    /// 実機ライブラリの品質を**正解ラベル無しで**測る（`FaceQualityReport` 参照）。
    /// Developer Options と診断ログから使う。O(クラスタ数²) の項があるので上限を設ける。
    func qualityReport(minFaces: Int, maxClustersForPairScan: Int = 1_500) -> FaceQualityReport {
        let allFaces = (countedFetchOptional(FetchDescriptor<DetectedFace>())) ?? []
        let clusters = allClusters()
        var report = FaceQualityReport()
        report.scannedPhotos = scannedCount()
        report.faces = allFaces.count
        report.unassignedFaces = allFaces.filter { $0.clusterID < 0 }.count
        report.clusters = clusters.count
        // ⚠️ `PersonCluster.count` は**重心に寄与した顔数**で、第2パス（ADR-66・membership のみ）で
        // 付いた低品質の顔を含まない。UI の人物数は実際の顔/写真で数えるため、両者は一致しない
        // （実機で UI 393 人 vs レポート 34 人という食い違いが出た）。表示は**実顔数**で数え、
        // アルゴリズムが見ている `count`（＝サイズ適応マージンや成熟判定の入力）は別に出す。
        var facesPerCluster: [Int: Int] = [:]
        for f in allFaces where f.clusterID >= 0 { facesPerCluster[f.clusterID, default: 0] += 1 }
        report.people = facesPerCluster.values.filter { $0 >= minFaces }.count
        report.singletons = facesPerCluster.values.filter { $0 == 1 }.count
        report.largestCluster = facesPerCluster.values.max() ?? 0
        report.namedPeople = clusters.filter { $0.name?.isEmpty == false }.count
        // 成熟判定はアルゴリズムと同じ土俵（重心寄与カウント）で数える。
        report.maturePeople = clusters.filter { $0.count >= FaceClustering.matureCountDefault }.count
        report.secondPassFaces = facesPerCluster.values.reduce(0, +)
            - clusters.reduce(0) { $0 + min($1.count, facesPerCluster[$1.clusterID] ?? 0) }
        report.threshold = calibratedThreshold()
        report.sizeExemptionActive = Self.rivalAwareSizeMargin
            && report.maturePeople < Self.rivalAwareSizeMarginMaxPeople
        report.corrections = (try? modelContext.fetchCount(FetchDescriptor<FaceCorrection>())) ?? 0
        // 顔が 1 つも見つからなかった写真（検出の取りこぼしの手がかり・保存済みデータから算出）。
        report.photosWithNoFace = ((countedFetchOptional(FetchDescriptor<ScannedPhoto>())) ?? [])
            .filter { $0.faceCount == 0 }.count

        // 同一写真違反: (写真, クラスタ) ごとの顔数が 2 以上。割り当ては cannot-link で防ぐが、
        // 統合（レビュー・手動）は検査していないので事後に検出する。
        var perPhotoCluster: [String: Int] = [:]
        for f in allFaces where f.clusterID >= 0 {
            perPhotoCluster["\(f.refKey)|\(f.clusterID)", default: 0] += 1
        }
        var violationPhotos = Set<String>()
        for (key, n) in perPhotoCluster where n >= 2 {
            report.samePhotoViolations += 1
            if let refKey = key.split(separator: "|").first { violationPhotos.insert(String(refKey)) }
        }
        report.samePhotoViolationPhotos = violationPhotos.count

        // 統合候補ペア（＝まだ畳めていない分裂）。レビューと同じ帯域・同じ抑制条件で数える。
        let targets = peopleEligibleClusters(minFaces: minFaces)
        guard targets.count <= maxClustersForPairScan else {
            report.mergeCandidateTruncated = true
            return report
        }
        var centroid: [Int: [Float]] = [:]
        var photoSets: [Int: Set<String>] = [:]
        var nameByID: [Int: String] = [:]
        for c in targets {
            nameByID[c.clusterID] = c.name ?? ""
            guard let sum = ClipMath.decodeHalf(c.sum) else { continue }
            centroid[c.clusterID] = FaceClustering.normalized(sum)
            photoSets[c.clusterID] = Set(faces(inCluster: c.clusterID).map(\.refKey))
        }
        let ids = targets.map(\.clusterID)
        for i in ids.indices {
            for j in (i + 1)..<ids.count {
                guard let a = centroid[ids[i]], let b = centroid[ids[j]] else { continue }
                guard FaceClustering.dot(a, b) >= tuning.mergeBandFloor(threshold: report.threshold) else { continue }
                guard (photoSets[ids[i]] ?? []).isDisjoint(with: photoSets[ids[j]] ?? []) else { continue }
                guard !Self.namesConflict(nameByID[ids[i]], nameByID[ids[j]]) else { continue }
                report.mergeCandidatePairs += 1
            }
        }
        return report
    }

    // MARK: - 一括レビュー（ADR-68）

    /// 「この人と同じ人を、まとめて選ぶ」1 画面ぶんを作る。
    ///
    /// 基準（アンカー）は `anchorClusterID` 指定がなければ **命名済みで最大**、無ければ最大の
    /// クラスタ。候補は A1 と同じ帯（重心類似 ≥ しきい値−0.10）から、別人記録・共起 notSame を
    /// 除いて類似度降順に採る。1 回答で `limit` 件まで畳めるので、A1（1 回答＝1 統合）に対して
    /// 桁で効率が上がる。
    /// - Parameters:
    ///   - excludingAnchors: 基準として使い終えた人物（「次の人へ」で送った分）。
    ///   - excludingCandidates: この基準について**出したが選ばれなかった**候補。
    ///     除外しないと同じ顔が延々と出続け、「候補が全部別人になる」＝機能が死ぬ（実フィードバック）。
    func batchReviewItem(minFaces: Int, anchorClusterID: Int? = nil,
                         excludingAnchors: Set<Int> = [],
                         excludingCandidates: Set<Int> = [],
                         limit: Int = 24) -> FaceBatchReviewItem? {
        let thr = calibratedThreshold()
        // UI の人物と同じ土俵で母数を取る（ADR-68 追補3）。
        let clusters = peopleEligibleClusters(minFaces: minFaces)
        guard clusters.count >= 2, !Task.isCancelled else { return nil }

        // 重心は `PersonCluster.sum` から作れる。**この段階では顔を 1 枚も読まない**
        // （ADR-123: 以前は全顔を射影で読んでから絞り込んでいた＝候補探しが数秒）。
        var centroid: [Int: [Float]] = [:]
        for c in clusters {
            guard let sum = ClipMath.decodeHalf(c.sum) else { continue }
            centroid[c.clusterID] = FaceClustering.normalized(sum)
        }

        // アンカー: 指定 → （使い終えた人物を除いて）**注目人物**の中で最大 → 最大。
        // 「次の人へ」で送った人物を除くことで、**基準を切り替えながら**畳めるようにする
        // （同じ基準に固定されると、真の一致を出し切った後は候補が全部別人になり機能が死ぬ）。
        let anchor: PersonCluster? = {
            if let id = anchorClusterID { return clusters.first { $0.clusterID == id } }
            let pool = Self.focusClusters(clusters).filter { !excludingAnchors.contains($0.clusterID) }
            return pool.max { $0.count < $1.count }
        }()
        guard let anchor, let anchorCentroid = centroid[anchor.clusterID] else { return nil }

        // 「別人」記録（A1 と同じ・重心埋め込みで照合）。
        let notSameRows = ((countedFetchOptional(FetchDescriptor<FaceCorrection>(
            // 「別人と答えた」対に加え、同一写真で統合できない対も出題から外す（ADR-152）。
            predicate: #Predicate { $0.kind == "notSame" || $0.kind == "samePhotoBlock" }))) ?? [])
            .compactMap {
            row -> ([Float], [Float])? in
            guard (row.profile ?? "facenet") == tuning.name else { return nil }   // 別空間（ADR-70 追補）
            guard let wrong = row.wrongEmbedding,
                  let a = ClipMath.decodeHalf(row.faceEmbedding),
                  let b = ClipMath.decodeHalf(wrong) else { return nil }
            return (FaceClustering.normalized(a), FaceClustering.normalized(b))
        }
        // ⚠️ 対ごとに全記録を走査しない（実機 diagnostics-61: 27.8 秒のハングの犯人）。
        // クラスタごとに「どの記録のどちら側へ一致するか」を先に求めておく（`NotSameIndex`）。
        let notSameIndex = NotSameIndex(rows: notSameRows, centroids: centroid)

        // まず**重心だけ**で候補を絞る（顔はまだ読まない）。
        var shortlist: [(cluster: PersonCluster, sim: Float)] = []
        for c in clusters where c.clusterID != anchor.clusterID {
            guard !excludingCandidates.contains(c.clusterID) else { continue }   // 出題済み
            guard let cen = centroid[c.clusterID] else { continue }
            let sim = FaceClustering.dot(anchorCentroid, cen)
            guard sim >= tuning.mergeBandFloor(threshold: thr),
                  !notSameIndex.isMarkedNotSame(anchor.clusterID, c.clusterID) else { continue }
            // 別々の名前が付いた対は出さない（追補5）。
            guard !Self.namesConflict(anchor.name, c.name) else { continue }
            shortlist.append((c, sim))
        }
        guard !shortlist.isEmpty, !Task.isCancelled else { return nil }
        shortlist.sort { $0.sim > $1.sim }
        // 表示は `limit` 件。共起で落ちる分の余裕を見て、その数倍だけ顔を読む。
        shortlist = Array(shortlist.prefix(limit * Self.candidateOverscan))

        // ここで初めて顔を読む——**基準と、絞り込んだ候補だけ**。
        var needed = Set(shortlist.map(\.cluster.clusterID))
        needed.insert(anchor.clusterID)
        let membersByCluster = faceDigests(inClusters: needed)
        var cover: [Int: PersonInfo.Face] = [:]
        var photoSets: [Int: Set<String>] = [:]
        let coverByCluster = Dictionary(uniqueKeysWithValues: clusters.map { ($0.clusterID, $0.coverFaceID) })
        for (id, members) in membersByCluster {
            photoSets[id] = Set(members.map(\.refKey))
            let pick = coverByCluster[id].flatMap { fid in members.first { $0.faceID == fid } }
                ?? members.max { $0.coverScore < $1.coverScore }
            if let f = pick {
                cover[id] = PersonInfo.Face(faceID: f.faceID, refKey: f.refKey, boundingBox: f.box)
            }
        }
        guard let anchorFace = cover[anchor.clusterID] else { return nil }

        let anchorPhotos = photoSets[anchor.clusterID] ?? []
        var candidates: [FaceBatchReviewItem.Candidate] = []
        for entry in shortlist {
            let c = entry.cluster
            guard let face = cover[c.clusterID] else { continue }
            // ⚠️ 共起は **1 回でも**あれば候補にしない（統合サジェストの 3 回とは別基準）。
            // 統合すると「1 枚の写真に同じ人物が 2 回」という不変条件が破れるため。
            // 実機で一括統合により違反が 2 件発生したのを受けて厳格化（ADR-68 追補4）。
            // 同一人物は 1 枚に 1 回しか写れないので、共起があれば別人か重複検出のどちらか。
            guard anchorPhotos.isDisjoint(with: photoSets[c.clusterID] ?? []) else { continue }
            candidates.append(.init(clusterID: c.clusterID, face: face,
                                    count: c.count, similarity: entry.sim))
        }
        guard !candidates.isEmpty else { return nil }

        return FaceBatchReviewItem(
            anchorClusterID: anchor.clusterID,
            anchorName: (anchor.name?.isEmpty == false) ? (anchor.name ?? "") : "",
            anchorFace: anchorFace, anchorCount: anchor.count,
            candidates: Array(candidates.prefix(limit)))
    }
}
