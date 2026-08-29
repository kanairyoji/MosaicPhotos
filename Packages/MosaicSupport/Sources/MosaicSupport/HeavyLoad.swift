import Foundation

/// **メモリを大きく積む一括ロード**が今走っているか（起動・復帰の集中砲火を重ねないための札）。
///
/// ⚠️ なぜ要るか（実機 diagnostics-65/66）: 起動直後の数秒に、73k 件のキャッシュ実体化・
/// 68k 件のパスアルバム計算・86k 件のマージ・18k 件のアセット索引が**同時に**走り、そこへ
/// 背景の CLIP テキストタワーのロード（実測 12.9 秒・約 120MB）が重なって footprint が
/// **569MB** まで伸びた。背面で 568MB のときは実際に jetsam で落ちている。
/// どれも単体では数百 ms〜1 秒で終わる健全な処理で、**重なることだけが問題**だった。
///
/// 方針: 起動の一括ロードは「今 走っている」と申告する。中断できない背景ロード
/// （モデルの読み込みなど）は、始める前にこの札を見て**順番を待つ**。
/// 逆はしない——ユーザーが待っている起動処理を、背景ロードのために遅らせることはない。
///
/// ⚠️ 安全弁つき: 申告したまま終了報告が来なくても、`maxSpanSeconds` を過ぎた札は
/// 無効とみなす。背景処理を**永久に止めない**（`isGeneratingAlbums` と同じ処方）。
public enum HeavyLoad {

    /// この時間を超えた札は「終わったのに報告が来ていない」とみなして無視する。
    /// 起動の一括ロードは実測 0.3〜1.5 秒なので、これで誤判定はしない。
    public static let maxSpanSeconds: TimeInterval = 30

    nonisolated(unsafe) private static var spans: [String: Date] = [:]
    private static let lock = NSLock()

    /// 一括ロードの開始を申告する。同じラベルの再入は最後の開始時刻で上書きする
    /// （同じ処理が重なって走ることはあり、片方の終了で札が消えると意味が無くなるため
    /// カウントで持つ）。
    public static func begin(_ label: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        counts[label, default: 0] += 1
        spans[label] = now
    }

    /// 終了を申告する（`begin` と対で必ず呼ぶ。`span` を使えば自動）。
    public static func end(_ label: String) {
        lock.lock(); defer { lock.unlock() }
        let remaining = (counts[label] ?? 0) - 1
        if remaining <= 0 {
            counts.removeValue(forKey: label)
            spans.removeValue(forKey: label)
        } else {
            counts[label] = remaining
        }
    }

    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    /// 一括ロードが 1 つでも走っているか（期限切れの札は数えない）。
    public static func isInFlight(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return spans.values.contains { now.timeIntervalSince($0) < maxSpanSeconds }
    }

    /// 走っているラベル（診断・テスト用）。
    public static func activeLabels(now: Date = Date()) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return spans.filter { now.timeIntervalSince($0.value) < maxSpanSeconds }.keys.sorted()
    }

    /// テスト用: 札を全部落とす。
    public static func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        spans.removeAll(); counts.removeAll()
    }

    /// 一括ロードを札つきで実行する（`defer` で必ず外れる）。
    public static func span<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
        begin(label)
        defer { end(label) }
        return try await body()
    }
}
