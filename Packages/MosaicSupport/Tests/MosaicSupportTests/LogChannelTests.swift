import Testing
@testable import MosaicSupport

@Suite("LogChannel")
struct LogChannelTests {
    // ログは副作用のみのため、各レベルが例外なく呼べることをスモークテストする。
    @Test("各レベルがクラッシュせず呼べる")
    func smoke() {
        let channel = LogChannel(subsystem: "com.mosaicphotos.test", label: "Test")
        channel.verbose("v")
        channel.info("i")
        channel.error("e")
    }

    @Test("autoclosure は遅延評価される（呼んだ事実だけ確認）")
    func autoclosureLazy() {
        let channel = LogChannel(subsystem: "com.mosaicphotos.test", label: "Test")
        var built = false
        channel.error({ built = true; return "x" }())
        #expect(built)   // error は常に評価される
    }
}
