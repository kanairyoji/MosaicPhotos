import Foundation

/// 顔検出ゲートの棄却内訳を実機で数える（ADR-68 追補2）。
///
/// 検出パイプラインは「候補を出す → 複数のゲートで絞る」構造で、**棄却の理由は
/// `debugAnalyze`（1 枚ずつの検証用）でしか見えなかった**。実ライブラリで
/// 「9,566 枚から顔 3,078 個（0.32 個/枚）＝取りこぼしが疑わしい」となったとき、
/// どのゲートが落としているのかを実機で確かめる手段が無い。
///
/// そこで**本番経路のまま**理由別に数える。しきい値を触る前に、まず内訳を測るための土台。
/// 計測は加算のみ（推論は挟まない）なので、スキャン性能への影響は無視できる。
public enum FaceDetectionStats {
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]
    private static var accepted = 0
    private static var belowFloor = 0
    private static var candidates = 0

    /// 1 顔ぶんの判定を記録する。
    /// - Parameters:
    ///   - reason: 棄却理由（通過は nil）。
    ///   - belowQualityFloor: 通過したが品質フロア未満＝クラスタに入らない（表示・第2パス送り）。
    public static func record(reason: String?, belowQualityFloor: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        candidates += 1
        if let reason {
            counts[reason, default: 0] += 1
        } else {
            accepted += 1
            if belowQualityFloor { belowFloor += 1 }
        }
    }

    public struct Snapshot: Sendable, Equatable {
        public var candidates: Int
        public var accepted: Int
        public var belowQualityFloor: Int
        public var rejectedByReason: [String: Int]

        /// 診断ログ 1 行。棄却の多い理由から並べる。
        public var logLine: String {
            let top = rejectedByReason.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            return "faces/detect: candidates=\(candidates) accepted=\(accepted) "
                + "belowFloor=\(belowQualityFloor)"
                + (top.isEmpty ? "" : " | rejected: \(top)")
        }
    }

    public static func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(candidates: candidates, accepted: accepted,
                        belowQualityFloor: belowFloor, rejectedByReason: counts)
    }

    public static func reset() {
        lock.lock(); defer { lock.unlock() }
        counts = [:]; accepted = 0; belowFloor = 0; candidates = 0
    }
}
