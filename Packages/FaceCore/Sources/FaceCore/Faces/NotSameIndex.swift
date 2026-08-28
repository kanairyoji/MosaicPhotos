import Foundation
import PerceptionCore

/// 「別人」記録（`FaceCorrection` の notSame）との照合を**前計算**する（純ロジック・テスト対象）。
///
/// ⚠️ なぜ要るか（実機 diagnostics-61・27.8 秒のハング）: 採取したメインスタックが名指しした。
///
///     FaceStore.reviewItems
///       → isMarkedNotSame #1 (Array<Float>, Array<Float>) -> Bool
///
/// 元の実装はクラスタ対の二重ループ（1,020 人＝約 52 万対）の**内側**で、
/// 「別人」記録を毎回すべて走査し、1 記録あたり 512 次元の内積を最大 4 回取っていた。
/// 記録が R 件あれば `対 × R × 4` 回の内積になり、人物と記録が増えるほど二乗で伸びる。
///
/// 判定式は「ある記録 i について（a が片側・b が反対側）に一致するか」なので、
/// **クラスタごとにどの記録のどちら側へ一致するか**を先に求めておけば、
/// 対の判定は集合が交わるかを見るだけで済む。前計算は `クラスタ数 × R`、
/// 対あたりは小さな集合演算のみ。判定結果は元の式と完全に一致する。
public struct NotSameIndex {

    /// 記録の「片側」に一致したクラスタ → 記録の添字。
    private var first: [Int: Set<Int>] = [:]
    /// 記録の「反対側」に一致したクラスタ → 記録の添字。
    private var second: [Int: Set<Int>] = [:]

    /// 一致とみなす内積のしきい値（元の実装と同じ 0.9）。
    public static let matchThreshold: Float = 0.9

    /// - Parameters:
    ///   - rows: 「別人」記録の対（どちらも正規化済みの重心埋め込み）。
    ///   - centroids: クラスタ ID → 正規化済み重心。
    public init(rows: [([Float], [Float])], centroids: [Int: [Float]],
                threshold: Float = NotSameIndex.matchThreshold) {
        guard !rows.isEmpty else { return }
        for (clusterID, centroid) in centroids {
            for (index, row) in rows.enumerated() {
                if FaceClustering.dot(centroid, row.0) >= threshold {
                    first[clusterID, default: []].insert(index)
                }
                if FaceClustering.dot(centroid, row.1) >= threshold {
                    second[clusterID, default: []].insert(index)
                }
            }
        }
    }

    /// この 2 クラスタは「別人」と記録済みか。
    ///
    /// 元の式（どちらかの記録で、a と b が反対側どうしに一致する）と同値:
    /// `(dot(a,ra)≥t && dot(b,rb)≥t) || (dot(a,rb)≥t && dot(b,ra)≥t)`
    public func isMarkedNotSame(_ a: Int, _ b: Int) -> Bool {
        if let fa = first[a], let sb = second[b], !fa.isDisjoint(with: sb) { return true }
        if let sa = second[a], let fb = first[b], !sa.isDisjoint(with: fb) { return true }
        return false
    }

    /// 記録が 1 件も無い（＝どの対も「別人」ではない）。
    public var isEmpty: Bool { first.isEmpty && second.isEmpty }
}
