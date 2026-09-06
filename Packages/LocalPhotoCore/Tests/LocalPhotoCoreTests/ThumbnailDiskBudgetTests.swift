import Foundation
import Testing
@testable import LocalPhotoCore

/// 端末写真サムネのディスク上限（Auto＝総容量の 10%）。
@Suite("ThumbnailDiskBudget")
struct ThumbnailDiskBudgetTests {
    @Test("Auto は総容量の 10%、500MB〜50GB にクランプ。読めなければ下限")
    func autoIsTenPercentClamped() {
        let gb = 1024 * 1024 * 1024
        #expect(ThumbnailDiskBudget.autoBytes(fromTotal: 128 * gb) == Int(Double(128 * gb) * 0.10))
        #expect(ThumbnailDiskBudget.autoBytes(fromTotal: 1 * gb) == ThumbnailDiskBudget.autoFloor, "小さすぎる端末は下限")
        #expect(ThumbnailDiskBudget.autoBytes(fromTotal: 2048 * gb) == ThumbnailDiskBudget.autoCeil, "上限で頭打ち")
        #expect(ThumbnailDiskBudget.autoBytes(fromTotal: 0) == ThumbnailDiskBudget.autoFloor)
    }

    @Test("設定値があればそれを使う（MB）")
    func explicitSettingWins() {
        #expect(ThumbnailDiskBudget.effectiveBytes(forSettingMB: 2048) == 2048 * 1024 * 1024)
    }
}
