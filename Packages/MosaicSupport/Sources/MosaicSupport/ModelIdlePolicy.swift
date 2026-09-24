import Foundation

/// 「使われていないモデルを手放してよいか」の線引き（純ロジック・テスト対象）。
///
/// ⚠️ 再ロードは実機で 10〜35 秒かかる（`MobileCLIPRuntime` の注記）。だから
/// **軽い圧迫では手放さない**という判断になっている。アイドル解放が成り立つのは
/// 「誰も待っていない時間に払うコストだから」で、線を短くするとその前提が崩れる
/// ——検索して結果を眺めている数分のあいだに手放すと、次の検索が 35 秒待ちになる。
public enum ModelIdlePolicy {

    /// 最後の推論からこれだけ経っていれば手放してよい（前面）。
    ///
    /// ⚠️ 5 分。短すぎると「検索 → 眺める → もう一度検索」で再ロードを踏む。
    /// 長すぎると放置中の常駐が減らない。窓の間隔（30 分）より十分短く、
    /// 一連の操作（数分）より十分長いところを採る。
    public static let idleSeconds: TimeInterval = 300

    /// - Parameters:
    ///   - lastUse: 最後に推論した時刻。**nil なら手放さない**（一度も使っていない＝
    ///     そもそも載っていないので、手放しても何も減らずログだけが増える）。
    ///   - analysisRunning: 解析が走っているか。走っていれば手放さない。
    public static func shouldRelease(lastUse: Date?, now: Date,
                                     idleSeconds: TimeInterval,
                                     analysisRunning: Bool) -> Bool {
        guard !analysisRunning else { return false }
        guard let lastUse else { return false }
        return now.timeIntervalSince(lastUse) >= idleSeconds
    }
}
