import Foundation

/// **記録された重心（sum/count）が、実際のメンバーと食い違っていないかを突き合わせる**
/// （純ロジック・テスト対象・ADR-210）。
///
/// ## なぜ要るか
/// 重心は**増分で更新される**——スキャンで足し、付け替えで引き、再クラスタで作り直す。
/// 増分更新は一度ずれると自力では戻らないうえ、ずれても**その場では何も起きない**。
/// 表に出るのは数手あとで、しかも症状が原因から遠い:
///
/// - `count` が実際より多い → 付け替えで引き切れず、`removing` の `count > 1` ガードに達して
///   **クラスタが消える**（残った顔は存在しない ID を指す）。
/// - `count` が実際より少ない → 1 枚外しただけで `sum` が零ベクトルになり、
///   **その人物には誰も合流しなくなる**。
/// - `sum` の向きだけがずれる → 本人の顔が入らず、別人が入る。
///
/// 実際に踏んだ形（`unresolved-problems.md`）: 品質フロア未満の顔を `sum` に足していないのに、
/// 書き戻しは「留めた顔はすべて寄与した」と記録していた。実ライブラリでは顔の約半数が
/// フロア未満なので、30 枚の人物で `count == 4` なのに 30 行が「寄与した」と言う状態になる。
///
/// ## 直し方ではなく「見つけ方」を置く
/// 再クラスタは全顔を読むので、**そのついでに突き合わせられる**（追加の読み出しゼロ）。
/// 見つけたら診断ログへ出し、再クラスタ自身が作り直して直す。次に同じずれが入れば、
/// また次の晩に見える——**黙って壊れ続ける状態が作れなくなる**のが目的。
public enum FaceCentroidAudit {

    /// 突き合わせに要る 1 顔ぶんの情報（埋め込みは別途クロージャで取る）。
    public struct Member: Sendable, Equatable {
        public let faceID: String
        public let quality: Float
        /// 行が「この顔は重心に寄与している」と言っているか。
        public let contributes: Bool
        public init(faceID: String, quality: Float, contributes: Bool) {
            self.faceID = faceID
            self.quality = quality
            self.contributes = contributes
        }
    }

    /// 1 クラスタぶんの記録された状態。
    public struct ClusterState: Sendable, Equatable {
        public let clusterID: Int
        public let storedSum: [Float]
        public let storedCount: Int
        public let members: [Member]
        public init(clusterID: Int, storedSum: [Float], storedCount: Int, members: [Member]) {
            self.clusterID = clusterID
            self.storedSum = storedSum
            self.storedCount = storedCount
            self.members = members
        }
    }

    public enum Kind: String, Sendable, Equatable {
        /// `count` が「寄与している」と言う顔の数と合わない。
        case countMismatch
        /// `sum` の向きが、寄与メンバーから作り直した向きとずれている。
        case sumDrift
        /// 寄与メンバーが居るのに `sum` が零ベクトル（誰も合流できない人物）。
        case emptyCentroid
    }

    public struct Finding: Sendable, Equatable {
        public let clusterID: Int
        public let kind: Kind
        public let storedCount: Int
        public let expectedCount: Int
        /// 記録された重心と作り直した重心のコサイン（1.0 = 一致）。比較不能なら 0。
        public let alignment: Float
    }

    /// 向きが「同じ」とみなす下限。Float16 で保存する（`ClipMath.encodeHalf`）ので、
    /// 完全一致は期待できない——量子化で動く程度（512 次元で 1e-3 未満）は許す。
    public static let minAlignment: Float = 0.999

    /// 寄与メンバーから `sum`/`count` を作り直す（`FaceClustering.adding` と同じ規則）。
    ///
    /// ⚠️ **`adding` と同じ式でなければ意味がない**。ここが本体とずれていたら、
    /// 監査そのものが嘘をつく（正しい重心を「壊れている」と言い、直しに行って壊す）。
    public static func expected(for cluster: ClusterState,
                                embedding: (String) -> [Float]?) -> (sum: [Float], count: Int) {
        var sum: [Float] = []
        var count = 0
        for member in cluster.members where member.contributes {
            guard let vector = embedding(member.faceID) else { continue }
            if sum.isEmpty { sum = [Float](repeating: 0, count: vector.count) }
            let added = FaceClustering.adding(vector, toSum: sum, count: count,
                                              quality: member.quality)
            sum = added.sum
            count = added.count
        }
        return (sum, count)
    }

    /// 食い違いを列挙する。**何も見つからなければ空**（正常時にログを汚さない）。
    public static func check(clusters: [ClusterState],
                             embedding: (String) -> [Float]?) -> [Finding] {
        var out: [Finding] = []
        for cluster in clusters.sorted(by: { $0.clusterID < $1.clusterID }) {
            let expected = Self.expected(for: cluster, embedding: embedding)
            let alignment = alignment(cluster.storedSum, expected.sum)
            // ⚠️ 寄与メンバーが 1 人も居ない人物は、**同一性を保つためだけに**重心の向きを
            // 残してある（全員が低品質・全員がユーザー指摘で外れた等）。作り物だと分かって
            // いる `count == 1` を食い違いとして毎晩挙げても、本物のずれが埋もれるだけ。
            if expected.count == 0 && cluster.storedCount <= 1 { continue }
            if cluster.storedCount != expected.count {
                out.append(Finding(clusterID: cluster.clusterID, kind: .countMismatch,
                                   storedCount: cluster.storedCount,
                                   expectedCount: expected.count, alignment: alignment))
                continue   // 件数がずれていれば向きのずれは当然（二重に数えない）
            }
            if expected.count > 0, norm(cluster.storedSum) <= 1e-6 {
                out.append(Finding(clusterID: cluster.clusterID, kind: .emptyCentroid,
                                   storedCount: cluster.storedCount,
                                   expectedCount: expected.count, alignment: 0))
                continue
            }
            if expected.count > 0, alignment < minAlignment {
                out.append(Finding(clusterID: cluster.clusterID, kind: .sumDrift,
                                   storedCount: cluster.storedCount,
                                   expectedCount: expected.count, alignment: alignment))
            }
        }
        return out
    }

    /// 2 つの生合計の向きの一致（正規化してから内積）。どちらかが零なら 0。
    static func alignment(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, norm(a) > 1e-6, norm(b) > 1e-6 else { return 0 }
        return FaceClustering.dot(FaceClustering.normalized(a), FaceClustering.normalized(b))
    }

    static func norm(_ v: [Float]) -> Float {
        var total: Float = 0
        for x in v { total += x * x }
        return total.squareRoot()
    }

    /// 診断ログ 1 行ぶんの要約（件数が多いときは重い順に数件だけ）。
    public static func summary(_ findings: [Finding], limit: Int = 5) -> String {
        guard !findings.isEmpty else { return "" }
        let worst = findings
            .sorted { abs($0.storedCount - $0.expectedCount) > abs($1.storedCount - $1.expectedCount) }
            .prefix(limit)
            .map { "\($0.clusterID):\($0.kind.rawValue) \($0.storedCount)→\($0.expectedCount)" }
            .joined(separator: ", ")
        return "\(findings.count) 件（\(worst)）"
    }
}
