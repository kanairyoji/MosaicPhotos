import MosaicSupport
import XCTest
@testable import MosaicPhotos

/// 飢餓の行が「どの窓の話か」を読めること（diagnostics-109）。
///
/// 期限切れの窓は手順の終わりを待たないので、5〜9 秒で切れた窓の続きは停止を跨いで
/// **30 分後の窓の頭で**走り、飢餓の行もそこで出る。印が無いと今の窓の飢餓と取り違える。
final class WindowStampTests: XCTestCase {

    func testStaleNoteNamesTheWindowOnlyAfterASuspension() throws {
        let began = try XCTUnwrap(Calendar.current.date(
            bySettingHour: 5, minute: 6, second: 33, of: Date()))
        let stamp = HeavyWorkScheduler.WindowStamp(began: began,
                                                   suspensionEpoch: ProcessSuspension.epoch)
        // ⚠️ 2 つの結果を区別できること（跨いでいない窓には何も添えない）。
        XCTAssertEqual(stamp.staleNote(), "", "停止を跨いでいない窓の行に印を付けた")

        ProcessSuspension.simulateSuspensionForTesting()
        let note = stamp.staleNote()
        XCTAssertTrue(note.contains("停止を跨いだ"), note)
        XCTAssertTrue(note.contains("05:06"), "どの窓の話か（始めた時刻）が無い: \(note)")
    }
}
