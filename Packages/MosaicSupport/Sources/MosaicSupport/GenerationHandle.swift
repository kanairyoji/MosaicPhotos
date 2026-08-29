import Foundation

/// 「いま走っている 1 つ」だけを指すハンドル（純ロジック・テスト対象）。
///
/// ⚠️ **手放すときも世代を照合するのが要点**（レビュー指摘）。実行 A をキャンセルしてから
/// 実行 B が始まり、そのあとで A が終了する——という順序は普通に起こる。単なる
/// `var current: Task?` だと、終了した A が `current = nil` として **B のハンドルを消す**。
/// 以後 B をキャンセルできず（フォアグラウンド復帰でも止まらない）、走っているかの表示も
/// 「走っていない」に見える。世代トークンを添え、自分が現行のときだけ手放す。
///
/// `@MainActor` 前提（BGTask のハンドラ・UI 状態と同じ文脈で扱う）。
@MainActor
public final class GenerationHandle<Value> {
    private var value: Value?
    private var token = 0

    public init() {}

    /// 現行として保持する（世代トークンつき）。
    public func set(_ value: Value, token: Int) {
        self.value = value
        self.token = token
    }

    /// 現在の値（無ければ nil）。
    public var current: Value? { value }

    /// 現行かどうかに関わらず手放す（明示キャンセル時など）。
    public func clear() { value = nil }

    /// **自分が現行のときだけ**手放す。
    /// - Returns: 実際に手放したか（false＝すでに次の実行のものに置き換わっていた）。
    @discardableResult
    public func clearIfCurrent(token: Int) -> Bool {
        guard self.token == token, value != nil else { return false }
        value = nil
        return true
    }
}

/// 「**最新の結果だけを反映する**」ための世代ガード（純ロジック・テスト対象）。
///
/// ⚠️ 何度も踏んだ形: 重い再構築をオフメインで走らせている最中に、次の再構築が始まる。
/// `Task.isCancelled` の確認と代入の間にキャンセルされる競合は防げないので、確認だけでは
/// **古いスナップショットが新しい結果を上書きし得る**（実機で「消したはずの一覧が戻る」
/// 「畳んだ地図が古いピンに戻る」として出た）。採番した世代を結果に添え、代入の直前に照合する。
///
/// 使い方:
/// ```swift
/// let token = generation.next()
/// let fresh = await Task.detached { heavy() }.value
/// guard generation.isCurrent(token) else { return }   // 追い越されていたら捨てる
/// items = fresh
/// ```
/// ⚠️ 「実行中の Task を安全に手放す」用途は `GenerationHandle`（上）。こちらは
/// **結果を反映してよいか**だけを見る。混ぜない。
@MainActor
public struct GenerationGuard {
    private var current = 0

    public init() {}

    /// 新しい世代を採番して返す（この実行の札）。
    public mutating func next() -> Int {
        current &+= 1
        return current
    }

    /// その札がまだ現行か（＝追い越されていないか）。
    public func isCurrent(_ token: Int) -> Bool { token == current }
}
