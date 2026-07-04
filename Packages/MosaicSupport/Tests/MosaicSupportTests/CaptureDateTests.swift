import Foundation
import Testing
@testable import MosaicSupport

@Suite("CaptureDate")
struct CaptureDateTests {

    @Test("nil は nil のまま")
    func nilStaysNil() {
        #expect(CaptureDate.meaningful(nil) == nil)
    }

    @Test("Unix epoch(1970)・DOS epoch(1980) などカメラ既定値は弾く")
    func rejectsEpochDefaults() {
        #expect(CaptureDate.meaningful(Date(timeIntervalSince1970: 0)) == nil)          // 1970-01-01
        #expect(CaptureDate.meaningful(Date(timeIntervalSince1970: 315_532_800)) == nil) // 1980-01-01
        #expect(CaptureDate.meaningful(Date(timeIntervalSince1970: 631_151_999)) == nil) // 1990 直前
    }

    @Test("1990-01-01 以降〜現在は通す")
    func acceptsNormalDates() {
        let d1990 = Date(timeIntervalSince1970: 631_152_000)
        #expect(CaptureDate.meaningful(d1990) == d1990)
        let now = Date()
        #expect(CaptureDate.meaningful(now) == now)
        let d2020 = Date(timeIntervalSince1970: 1_577_836_800)
        #expect(CaptureDate.meaningful(d2020) == d2020)
    }

    @Test("未来は+2日まで許容（タイムゾーンずれ対策）、それ以降は弾く")
    func rejectsFarFuture() {
        let tomorrow = Date(timeIntervalSinceNow: 86_400)
        #expect(CaptureDate.meaningful(tomorrow) == tomorrow)
        let nextMonth = Date(timeIntervalSinceNow: 30 * 86_400)
        #expect(CaptureDate.meaningful(nextMonth) == nil)
    }
}
