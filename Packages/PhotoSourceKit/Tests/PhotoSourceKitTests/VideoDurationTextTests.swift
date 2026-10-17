import Foundation
import Testing
@testable import PhotoSourceKit

/// グリッドのセル右下に出す動画の再生時間（写真アプリと同じ書式）。
@Suite("VideoDurationText")
struct VideoDurationTextTests {
    @Test("1 時間未満は m:ss、以上は h:mm:ss")
    func formats() {
        #expect(VideoDurationText.format(0) == "0:00")
        #expect(VideoDurationText.format(5) == "0:05")
        #expect(VideoDurationText.format(62) == "1:02")
        #expect(VideoDurationText.format(599) == "9:59")
        #expect(VideoDurationText.format(3600) == "1:00:00")
        #expect(VideoDurationText.format(3723) == "1:02:03")
    }

    @Test("秒は四捨五入（0.6 秒は 0:01・59.6 秒は 1:00）")
    func rounds() {
        #expect(VideoDurationText.format(0.4) == "0:00")
        #expect(VideoDurationText.format(0.6) == "0:01")
        #expect(VideoDurationText.format(59.6) == "1:00")
    }

    @Test("負・非有限は出さない")
    func rejectsInvalid() {
        #expect(VideoDurationText.format(-1) == nil)
        #expect(VideoDurationText.format(.nan) == nil)
        #expect(VideoDurationText.format(.infinity) == nil)
    }
}

/// グリッドのセル右下の印（ADR-282）。長さを訊く前のクラウドの動画にも印を出す。
@Suite("GridVideoBadge")
struct GridVideoBadgeTests {
    @Test("写真には何も出さない・長さが分かれば時間・分からなければ印だけ")
    func badges() {
        #expect(GridVideoBadge.badge(mediaKind: .photo, duration: 12) == nil)
        #expect(GridVideoBadge.badge(mediaKind: .video, duration: 62) == .duration("1:02"))
        #expect(GridVideoBadge.badge(mediaKind: .video, duration: nil) == .unknownLength)
        #expect(GridVideoBadge.badge(mediaKind: .video, duration: -1) == .unknownLength)
    }
}
