import Testing
@testable import MosaicSupport

/// ⚠️ 実行 A をキャンセル → 実行 B が開始 → **その後で A が終了**、という順序は普通に起こる。
/// 終了した A が現行ハンドルを無条件に nil にすると、B を止められなくなる。
@Suite("GenerationHandle")
@MainActor
struct GenerationHandleTests {

    @Test("終わった旧世代は、次の実行のハンドルを消さない")
    func staleCompletionKeepsCurrentHandle() {
        let handle = GenerationHandle<String>()
        handle.set("A", token: 1)
        handle.set("B", token: 2)          // A をキャンセルして B が始まった

        let cleared = handle.clearIfCurrent(token: 1)   // 遅れて A が終了

        #expect(!cleared)
        #expect(handle.current == "B", "旧世代が現行のハンドルを消した（以後 B を止められない）")
    }

    @Test("現行が終わったら手放す")
    func currentCompletionClears() {
        let handle = GenerationHandle<String>()
        handle.set("A", token: 1)
        #expect(handle.clearIfCurrent(token: 1))
        #expect(handle.current == nil)
    }

    @Test("二重の完了で次の実行を消さない")
    func doubleCompletionIsIdempotent() {
        let handle = GenerationHandle<String>()
        handle.set("A", token: 1)
        #expect(handle.clearIfCurrent(token: 1))
        handle.set("B", token: 2)
        #expect(!handle.clearIfCurrent(token: 1), "A の二度目の完了で B が消えた")
        #expect(handle.current == "B")
    }

    @Test("明示キャンセルは世代に関わらず手放す")
    func explicitClearAlwaysClears() {
        let handle = GenerationHandle<String>()
        handle.set("A", token: 7)
        handle.clear()
        #expect(handle.current == nil)
    }
}
