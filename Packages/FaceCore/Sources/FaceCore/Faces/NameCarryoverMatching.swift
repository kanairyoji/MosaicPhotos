import Foundation

/// 版上げ後の「名前の持ち越し」を、旧人物と新クラスタの**一対一対応**として解く純ロジック（ADR-169）。
///
/// ## なぜ貪欲ではいけないか
/// 旧人物ごとに「重なり最大の新クラスタ」を選ぶと、**局所的な最良ペアが、別の旧人物にとって
/// 唯一の対応先を奪う**。存在するはずの一対一対応を見逃し、片方の名前が戻らない。
///
/// ```
///   旧A（重なり X=5 / Y=4）  旧B（重なり X=3 のみ）
///   貪欲: A→X を取る → B は候補なし（名前が戻らない）
///   正解: A→Y, B→X（2 人とも戻る）
/// ```
///
/// ## 同名の別人（この不具合の本体）
/// 「同じ名前のクラスタが既にある」ことを理由に**エントリを捨ててはいけない**。
/// 同名の別人（"太郎" が 2 人）は普通にあり、捨てると 2 人目の名前と旧メンバーの対応が
/// **永久に失われる**（残りにも積まれないので再試行もされない）。
/// 対応先が決まらないエントリは必ず「残り」として返し、後続のスキャンで再評価させる。
///
/// ## 解き方
/// **最大マッチング**（Kuhn の増加道法）で「戻せる名前の数」を最大にする。候補は重なりの
/// 多い順に見るので、同数を戻せる割り当てが複数あるときは重なりの大きい対を優先する。
/// 旧人物は多くて数十なので、この規模では計算量は問題にならない。
public enum NameCarryoverMatching {

    /// 1 件の持ち越し候補（旧人物 1 人ぶん）。
    public struct Entry: Sendable, Equatable {
        public let name: String
        /// 新クラスタ ID → 旧メンバー写真との重なり枚数。**足切り済み**のものを渡すこと。
        public let candidates: [Int: Int]
        public init(name: String, candidates: [Int: Int]) {
            self.name = name
            self.candidates = candidates
        }
    }

    /// - Returns: `assignments`＝エントリ番号 → 割り当てた新クラスタ ID。
    ///   `unmatched`＝対応先が決まらなかったエントリ番号（**呼び出し側は残りとして保持する**）。
    public static func match(_ entries: [Entry])
        -> (assignments: [Int: Int], unmatched: [Int]) {
        guard !entries.isEmpty else { return ([:], []) }

        // 候補は重なりの多い順（同数なら clusterID 昇順＝結果を決定的にする）。
        let ordered: [[Int]] = entries.map { entry in
            entry.candidates.sorted {
                $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
            }.map(\.key)
        }

        var clusterToEntry: [Int: Int] = [:]

        /// 増加道を 1 本探す（Kuhn）。`visited` は 1 回の探索で使い回す。
        func augment(_ entryIndex: Int, _ visited: inout Set<Int>) -> Bool {
            for cluster in ordered[entryIndex] where visited.insert(cluster).inserted {
                // 空いている、または今の持ち主が別の相手へ移れるなら奪える。
                if clusterToEntry[cluster] == nil || augment(clusterToEntry[cluster]!, &visited) {
                    clusterToEntry[cluster] = entryIndex
                    return true
                }
            }
            return false
        }

        // 候補が少ないエントリから解く（選択肢の少ない側を先に確定させる方が詰みにくい）。
        let order = entries.indices.sorted {
            let a = ordered[$0].count, b = ordered[$1].count
            return a != b ? a < b : $0 < $1
        }
        for index in order {
            var visited = Set<Int>()
            _ = augment(index, &visited)
        }

        var assignments: [Int: Int] = [:]
        for (cluster, entryIndex) in clusterToEntry { assignments[entryIndex] = cluster }
        let unmatched = entries.indices.filter { assignments[$0] == nil }
        return (assignments, unmatched)
    }
}
