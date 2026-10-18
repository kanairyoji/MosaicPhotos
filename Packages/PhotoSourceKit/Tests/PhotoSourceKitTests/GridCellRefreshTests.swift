import Foundation
import Testing
@testable import PhotoSourceKit

/// 構成が変わらない更新で、表示中のセルを作り直すか（ADR-282 のレビュー指摘）。
/// ⚠️ 長さだけが後から分かる動画で作り直さないと、スクロールするまで動画の印が残る。
@Suite("グリッド: 表示中のセルを作り直すか")
struct GridCellRefreshTests {

    private struct Item: PhotoItem {
        let id = "C-/v.mov"
        var captureDate: Date? = nil
        var isFavorite = false
        var videoDuration: TimeInterval?
    }

    @Test("動画の長さが変われば作り直す（不明→値・値→別の値・値→不明）")
    func durationChanges() {
        #expect(GridCellRefresh.needsReconfigure(old: Item(videoDuration: nil), new: Item(videoDuration: 65)))
        #expect(GridCellRefresh.needsReconfigure(old: Item(videoDuration: 65), new: Item(videoDuration: 70)))
        #expect(GridCellRefresh.needsReconfigure(old: Item(videoDuration: 65), new: Item(videoDuration: nil)))
    }

    @Test("お気に入りが変われば作り直す")
    func favoriteChanges() {
        #expect(GridCellRefresh.needsReconfigure(old: Item(isFavorite: false), new: Item(isFavorite: true)))
    }

    /// 逆向きの縛り: 何も変わらない更新で作り直さない（同期中は 0.4 秒ごとに反映が来る）。
    @Test("見た目に効く項目が同じなら作り直さない")
    func unchanged() {
        #expect(!GridCellRefresh.needsReconfigure(old: Item(videoDuration: 65), new: Item(videoDuration: 65)))
        #expect(!GridCellRefresh.needsReconfigure(old: Item(), new: Item()))
    }
}
