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
    /// ⚠️ `internal`。本番の呼び出しは同じファイルの `consumeIfIdle` **1 か所だけ**で、
    /// モジュールの外から使う理由が無い（判定と記録消去は不可分なので、外から
    /// 判定だけ呼べると「消し忘れ」を作れてしまう）。テストは `@testable` で見る。
    static func shouldRelease(lastUse: Date?, now: Date,
                              idleSeconds: TimeInterval,
                              analysisRunning: Bool) -> Bool {
        guard !analysisRunning else { return false }
        guard let lastUse else { return false }
        return now.timeIntervalSince(lastUse) >= idleSeconds
    }
}

/// 「最後にモデルを使った時刻」を持ち、**判定と消去をひと続きで**行う入れ物。
///
/// ⚠️ なぜ別の型にしたか（レビュー 3 周目）: 状態を `PerceptionModels` の static に置き、
/// 「判定 → 手放す → 記録を消す」と 3 段で書いていた。ところが `note()` は**推論の
/// スレッドから**、判定は**メインから**呼ばれるので、この 3 段の途中に `note()` が
/// 割り込める。割り込むと、**たった今使い始めた印を最後の消去が上書きして消す**
/// ——その直後に手放す判断が下り、走り始めた推論からモデルを取り上げることになる。
/// 判定と消去を錠の中で 1 つにすれば、割り込みは「消去の前」か「後」のどちらかに定まる。
///
/// ⚠️ `note()` は推論の**開始時**に呼ぶこと（ゲートに入る前）。終了時にすると、
/// ゲートで順番待ちしている長い推論が「使っていない」と見えてしまう。
public final class ModelIdleTracker: @unchecked Sendable {

    /// ⚠️ **`shared` は置かない**（レビュー指摘）。モデルごとに 1 つ持つ
    /// ——CLIP と顔モデルで 1 つの記録を共有すると、**写真を眺めているだけで走る
    /// CLIP の推論が、何時間も使っていない顔モデル（300〜650MB）を引き止める**
    /// （表示タグの `CLIPDisplayLabeler` が数分おきに走るので、記録が 5 分を超えない）。
    /// これでは ADR-228 がいちばん減らしたい場面で減らない。所有は `PerceptionModels`。

    private let lock = NSLock()
    private var lastUse: Date?

    public init() {}

    /// 推論が走ったことを記録する。
    public func note(now: Date = Date()) {
        lock.lock(); lastUse = now; lock.unlock()
    }

    /// **手放してよいなら記録を消して true を返す**（判定と消去は不可分）。
    ///
    /// 消すのは「このアイドル期間はもう処理した」の印。消さないと 5 秒ごとに判定が通り続け、
    /// そのたびにランタイムの `shared` へ触りにいく（`static let shared` なので
    /// **使っていないランタイムを起こしてしまう**）。
    public func consumeIfIdle(now: Date = Date(), idleSeconds: TimeInterval,
                              analysisRunning: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard ModelIdlePolicy.shouldRelease(lastUse: lastUse, now: now,
                                            idleSeconds: idleSeconds,
                                            analysisRunning: analysisRunning) else { return false }
        lastUse = nil
        return true
    }
}
