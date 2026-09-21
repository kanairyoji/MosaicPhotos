import Foundation

/// **服装（胴体）を 2 つ目の手がかりにして、顔が当てにならない写真を繋ぐ**
/// （純ロジック・テスト対象・ADR-212）。
///
/// ## なぜ要るか
/// 実ライブラリでは顔の約 48% が品質フロア未満で、埋め込みだけを頼りにしている。
/// 横を向いた・ぶれた・小さく写った顔は、どれだけ正しく埋め込んでも情報が足りない。
/// 一方その写真には**同じ人を指すもう 1 つの証拠**がある——同じ場面で同じ服を着ている。
///
/// ## 使ってよい範囲を先に決める（ここが安全弁のすべて）
/// 服は「その人のもの」ではなく「その日のもの」で、しかも兄弟や制服では共有される。
/// だから次の条件を**全部**満たすときだけ使う:
///
/// 1. **同じ場面の中だけ**（既定 1 時間以内で連なる写真）。日をまたいだら服は別物。
/// 2. **両方が胴体を持つときだけ**寄与する。片方でも欠けたら顔だけの判断に戻る（無音で）。
/// 3. **胴体だけで人物を作らない**。繋ぎ先は「その場面で**顔が**確立している人物」に限る。
///    ——ここを緩めると、お揃いの服・制服で人物が丸ごと混ざる。
/// 4. **重心には決して足さない**。所属（membership）だけ。間違いは 1 枚外せば直る。
/// 5. **1 位と 2 位が紛らわしければ繋がない**（マージンゲート・ADR-57 と同じ考え方）。
///
/// ## 尺度が違うものをどう混ぜるか
/// 顔（ArcFace）と胴体（CLIP 画像埋め込み）はコサインの**分布がまったく違う**
/// ——CLIP は無関係な画像どうしでも 0.5 を超える。絶対値を足し算して 1 本のバーで切ると、
/// 片方の尺度に引きずられて意味を失う。
///
/// そこで **順位は重み付き和（顔 7 : 胴体 3）、可否は相対差**で決める:
/// 1 つの顔について複数の人物を比べるとき、顔の尺度も胴体の尺度も**その顔の中では一定**
/// なので、重み付き和は正しい順位づけになる。採否は「1 位と 2 位の差」で見るので
/// 尺度に依らない。絶対値を使うのは**胴体が実質同じ写り**かを見る 1 か所だけで、
/// そこは「ほぼ複製」を判定するだけなので分布に鈍い（負例の重複判定・ADR-140 と同じ役割）。
public enum TorsoLinking {

    public struct Face: Sendable, Equatable {
        public let faceID: String
        public let refKey: String
        public let captureDate: Date?
        /// 現在の割り当て（未割当は `FaceClustering.unassigned`）。
        public let clusterID: Int
        /// 重心を作った顔か。**この顔だけが「その場面で確立している人物」の証拠になる。**
        public let contributes: Bool
        /// 顔の埋め込み（正規化前でよい）。
        public let embedding: [Float]
        /// 胴体の埋め込み（無ければ nil＝この顔は胴体の判断に参加しない）。
        public let torso: [Float]?

        public init(faceID: String, refKey: String, captureDate: Date?, clusterID: Int,
                    contributes: Bool, embedding: [Float], torso: [Float]?) {
            self.faceID = faceID
            self.refKey = refKey
            self.captureDate = captureDate
            self.clusterID = clusterID
            self.contributes = contributes
            self.embedding = embedding
            self.torso = torso
        }
    }

    public struct Link: Sendable, Equatable {
        public let faceID: String
        public let clusterID: Int
        public let faceSimilarity: Float
        public let torsoSimilarity: Float
        public init(faceID: String, clusterID: Int, faceSimilarity: Float, torsoSimilarity: Float) {
            self.faceID = faceID
            self.clusterID = clusterID
            self.faceSimilarity = faceSimilarity
            self.torsoSimilarity = torsoSimilarity
        }
    }

    public struct Plan: Sendable, Equatable {
        public var links: [Link] = []
        /// 胴体を持つ候補のうち、条件に合わず繋がなかった数（「走って 0 件」を見分ける・ADR-157）。
        public var skipped: Int = 0
        /// **バーを動かす判断の材料**（ADR-162 と同じやり方）。バー以外の条件を全部通った
        /// 候補が、どの胴体類似に何件あるか。実機のログを見れば「0.85 にしたら何件増えるか」が
        /// そのまま読める——データセットに胴体が無い以上、決めるのはこの分布しかない。
        public var probe: [Float: Int] = [:]
    }

    /// 同じ場面とみなす写真間の最大間隔（既定 1 時間）。
    /// ⚠️ 長くすると「同じ日の別の服」「別の場所の似た服」を拾う。
    public static let defaultSessionGap: TimeInterval = 3600

    /// 順位づけの重み（顔 7 : 胴体 3）。顔が主で、胴体は決め手ではなく**後押し**。
    public static let faceWeight: Float = 0.7

    /// 胴体が「実質同じ写り」と言える下限（CLIP コサイン）。
    ///
    /// ⚠️⚠️ **暫定値**。顔のデータセット（FG-NET / LFW）は顔のクロップだけで、胴体も場面の
    /// 構造も持たないので、ここはデータセットでは決められない。そこで
    /// (1) 保守的に高く置き、(2) `Plan.probe` に分布を出し、(3) 実機で「この繋がりを
    /// ユーザーが何割外したか」（`linkSource` 別の付け替え率）を見て決める——
    /// 断片吸収のバーを実機の分布で決めた ADR-162 と同じ手順を踏む。
    public static let defaultTorsoBar: Float = 0.90

    /// 1 位と 2 位の差（重み付き和）。これ未満は「紛らわしい」として繋がない。
    public static let defaultScoreMargin: Float = 0.05

    /// 分布を出す探りのバー。
    public static let probeBars: [Float] = [0.80, 0.85, 0.90, 0.95]

    /// 順位づけのスコア（顔 7 : 胴体 3）。
    public static func score(face: Float, torso: Float, faceWeight: Float = faceWeight) -> Float {
        faceWeight * face + (1 - faceWeight) * torso
    }

    /// **場面の切れ目**（撮影日の昇順配列に対する区間）。
    ///
    /// ⚠️ 呼び出し側が**場面ごとに流し込める**ように切り出してある。全顔の `[Float]` を
    /// 一度に持つと 86k × 512 次元 × 4 バイト ≒ 176MB になる（ADR-6/119/122 が繰り返し
    /// 扱ってきた形）。場面は数十〜数百枚なので、区間ごとに復号して捨てれば有界に収まる。
    public static func sessionBoundaries(dates: [Date],
                                         gap: TimeInterval = defaultSessionGap) -> [Range<Int>] {
        guard !dates.isEmpty else { return [] }
        var out: [Range<Int>] = []
        var start = 0
        for index in 1..<dates.count where dates[index].timeIntervalSince(dates[index - 1]) > gap {
            out.append(start..<index)
            start = index
        }
        out.append(start..<dates.count)
        return out
    }

    /// - Parameters:
    ///   - faceFloor: 顔の最低線。胴体が後押しする前提で第2パスより**低く**置く
    ///     （`FaceTuning.torsoFaceFloor`）。ここを外すと胴体だけで決まってしまう。
    ///   - isBlocked: (faceID, clusterID) → 繋いではいけないか（負例・「別人」記録）。
    public static func plan(faces: [Face],
                            sessionGap: TimeInterval = defaultSessionGap,
                            torsoBar: Float = defaultTorsoBar,
                            scoreMargin: Float = defaultScoreMargin,
                            faceFloor: Float,
                            isBlocked: (String, Int) -> Bool = { _, _ in false }) -> Plan {
        var plan = Plan()
        for bar in probeBars { plan.probe[bar] = 0 }
        let dated = faces.filter { $0.captureDate != nil && $0.torso != nil }
        guard dated.count >= 2 else { return plan }

        // ⚠️ 並べ替えは (撮影日, refKey, faceID) で完全に決定的にする。
        let sorted = dated.sorted {
            let da = $0.captureDate ?? .distantPast, db = $1.captureDate ?? .distantPast
            if da != db { return da < db }
            if $0.refKey != $1.refKey { return $0.refKey < $1.refKey }
            return $0.faceID < $1.faceID
        }
        var session: [Face] = []
        var lastDate: Date?
        for face in sorted {
            let date = face.captureDate ?? .distantPast
            if let lastDate, date.timeIntervalSince(lastDate) > sessionGap {
                appendSession(session, torsoBar: torsoBar, scoreMargin: scoreMargin,
                              faceFloor: faceFloor, isBlocked: isBlocked, into: &plan)
                session = []
            }
            session.append(face)
            lastDate = date
        }
        appendSession(session, torsoBar: torsoBar, scoreMargin: scoreMargin,
                      faceFloor: faceFloor, isBlocked: isBlocked, into: &plan)
        plan.links.sort { $0.faceID < $1.faceID }
        return plan
    }

    private static func appendSession(_ session: [Face], torsoBar: Float, scoreMargin: Float,
                                      faceFloor: Float, isBlocked: (String, Int) -> Bool,
                                      into plan: inout Plan) {
        guard session.count >= 2 else { return }
        // その場面で**顔が**確立している人物（＝繋ぎ先の候補）。胴体だけの人物は作らない。
        var anchorsByCluster: [Int: [Face]] = [:]
        for face in session where face.contributes && face.clusterID >= 0 && face.torso != nil {
            anchorsByCluster[face.clusterID, default: []].append(face)
        }
        guard !anchorsByCluster.isEmpty else { return }
        // ⚠️ 反復順序に依存しない（クラスタ ID 昇順で回す）。
        let clusterIDs = anchorsByCluster.keys.sorted()

        // その写真に既に居る人物（同一写真 cannot-link）。
        var occupancy: [String: Set<Int>] = [:]
        for face in session where face.clusterID >= 0 {
            occupancy[face.refKey, default: []].insert(face.clusterID)
        }

        for candidate in session where candidate.clusterID < 0 {
            guard let torso = candidate.torso else { continue }
            let torsoVector = FaceClustering.normalized(torso)
            let faceVector = FaceClustering.normalized(candidate.embedding)
            var scored: [(clusterID: Int, face: Float, torso: Float, score: Float)] = []
            for clusterID in clusterIDs {
                guard let anchors = anchorsByCluster[clusterID] else { continue }
                var bestFace: Float = -1, bestTorso: Float = -1
                for anchor in anchors {
                    bestFace = max(bestFace, FaceClustering.dot(
                        faceVector, FaceClustering.normalized(anchor.embedding)))
                    if let anchorTorso = anchor.torso {
                        bestTorso = max(bestTorso, FaceClustering.dot(
                            torsoVector, FaceClustering.normalized(anchorTorso)))
                    }
                }
                guard bestTorso > -1 else { continue }
                scored.append((clusterID, bestFace, bestTorso,
                               score(face: bestFace, torso: bestTorso)))
            }
            guard !scored.isEmpty else { continue }
            // 同点はクラスタ ID の小さい方（決定的に）。
            scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.clusterID < $1.clusterID }
            let best = scored[0]

            // バー以外の条件をすべて通ったか（＝探りの分布に数えてよいか）。
            let marginOK = scored.count < 2 || (best.score - scored[1].score) >= scoreMargin
            let torsoLeads = scored.count < 2 || best.torso >= scored[1].torso
            let freePhoto = !(occupancy[candidate.refKey]?.contains(best.clusterID) ?? false)
            let qualifies = marginOK && torsoLeads && best.face >= faceFloor && freePhoto
                && !isBlocked(candidate.faceID, best.clusterID)
            guard qualifies else { plan.skipped += 1; continue }
            for bar in probeBars where best.torso >= bar { plan.probe[bar, default: 0] += 1 }

            guard best.torso >= torsoBar else { plan.skipped += 1; continue }
            plan.links.append(Link(faceID: candidate.faceID, clusterID: best.clusterID,
                                   faceSimilarity: best.face, torsoSimilarity: best.torso))
            occupancy[candidate.refKey, default: []].insert(best.clusterID)
        }
    }
}
