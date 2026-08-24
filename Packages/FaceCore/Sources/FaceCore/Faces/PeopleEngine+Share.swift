import Foundation

/// 家族共有（ADR-112）の顔シグナル輸出入ファサード。
extension PeopleEngine {

    /// refKey 群の検出顔シグナル（サイドカー輸出用）。
    public func exportFaceSignals(forRefKeys keys: [String]) async -> [String: [DetectedFaceSignal]] {
        guard !keys.isEmpty else { return [:] }
        return await store.faceSignals(forRefKeys: keys)
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
        setNeedsPeopleReload()
        return (saved ? fresh.count : 0, saved)
    }
}
