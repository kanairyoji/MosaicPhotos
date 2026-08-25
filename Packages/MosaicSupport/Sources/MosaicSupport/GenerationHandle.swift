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
