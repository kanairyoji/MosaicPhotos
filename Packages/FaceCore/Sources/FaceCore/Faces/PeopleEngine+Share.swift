import Foundation
import MosaicSupport

/// 家族共有（ADR-112）の顔シグナル輸出入ファサード。
extension PeopleEngine {

    /// refKey 群の検出顔シグナル（サイドカー輸出用）。
    /// - Parameter includeNames: 自分が付けた人物名も載せるか（ADR-167・設定で切れる）。
    public func exportFaceSignals(forRefKeys keys: [String],
                                  includeNames: Bool = false) async -> [String: [DetectedFaceSignal]] {
        guard !keys.isEmpty else { return [:] }
        return await store.faceSignals(forRefKeys: keys, includeNames: includeNames)
    }

    /// 家族のサイドカー由来の顔シグナルを取り込む。**未スキャンの写真だけ**記録し
    /// （スキャン済みは受信側の自前解析が優先・`recordScan` のマーカーでも二重防止）、
    /// 逐次クラスタリングで既存の人物へ割り当てる。
    /// - Returns: 取り込んだ写真数と**永続化できたか**。呼び出し側は保存できたときだけ
    ///   サイドカーを「取り込み済み」として記録する（レビュー指摘）。
    @discardableResult
    public func importFaceScans(_ batch: [(refKey: String, faces: [DetectedFaceSignal])]) async
        -> (photos: Int, saved: Bool) {
        guard !batch.isEmpty else { return (0, true) }
        let unscanned = Set(await store.unscannedRefKeys(from: batch.map(\.refKey)))
        let fresh = batch.filter { unscanned.contains($0.refKey) }
        guard !fresh.isEmpty else { return (0, true) }
        let saved = await store.recordScans(fresh)
        // 家族が付けた名前を**提案として**取り込む（ADR-167）。
        // ⚠️ 自分が既に付けた名前は上書きしない——名前は持ち主の判断で、
        // 受信のたびに相手の呼び方へ書き換わるのは事故に近い。
        if saved {
            let named = await store.applySharedNames(fresh)
            if named > 0 { Diagnostics.mark("share: 家族の人物名を \(named) 人に取り込みました") }
        }
        setNeedsPeopleReload()
        return (saved ? fresh.count : 0, saved)
    }
}
