import Foundation
import Testing
@testable import DropboxCore

/// 軽い表のディスク控え（ADR-258・実機ログ diagnostics-105）。
///
/// ⚠️ 表は作り直せるのでメモリにしか持っておらず、**毎起動 1 回**10.8 万行を歩き直していた
/// （`cache.buildItemIndex` 9.0 秒・その間 actor は塞がる）。
/// ADR-229「作り直せる表はキー付きでディスクへ」がここに適用されていなかった。
@Suite("軽い表のディスク控え")
struct ItemIndexSnapshotTests {

    private func row(_ path: String, hash: String? = "h", date: Date? = nil,
                     probed: Bool = false) -> DropboxItemIndexSnapshot.Row {
        .init(path: path, hash: hash, captureDate: date, probed: probed)
    }

    @Test("書いて読むと同じものが返る")
    func roundTrips() {
        let rows = [
            row("/Photos/2019/IMG_1.jpg", hash: "abc123",
                date: Date(timeIntervalSince1970: 1_500_000_000), probed: true),
            row("/日本語/沖縄 旅行/写真.jpeg", hash: nil, date: nil, probed: false),
            row("/Mixed/CaseIsKept.JPG", hash: "d", date: Date(timeIntervalSince1970: 0),
                probed: true)
        ]
        let payload = DropboxItemIndexSnapshot.Payload(contentVersion: 42, rows: rows)
        let decoded = DropboxItemIndexSnapshot.decode(DropboxItemIndexSnapshot.encode(payload))
        #expect(decoded == payload, "往復で値が変わっている")
    }

    /// ⚠️ **0 は 1970-01-01 という実在する日付**。nil を 0 で表すと「撮影日が 1970 年の写真」に
    /// なり、並び順（新しい順）の末尾に居座る。NaN で表すこと。
    @Test("撮影日の「無し」と 1970-01-01 を区別する")
    func distinguishesNilDateFromEpoch() {
        let payload = DropboxItemIndexSnapshot.Payload(contentVersion: 1, rows: [
            row("/a.jpg", date: nil),
            row("/b.jpg", date: Date(timeIntervalSince1970: 0))
        ])
        let decoded = DropboxItemIndexSnapshot.decode(DropboxItemIndexSnapshot.encode(payload))
        #expect(decoded?.rows[0].captureDate == nil)
        #expect(decoded?.rows[1].captureDate == Date(timeIntervalSince1970: 0))
    }

    /// ⚠️⚠️ **途中まで読めた分を返さない**。`buildItemIndex` が同じ事故で
    /// 「欠けた表を完成品として保存する」を起こしかけている（そちらのコメント参照）。
    /// 控えでも同じで、欠けた表を受け入れると次の起動が欠けたまま走る。
    @Test("途中で切れた控えは、途中結果を返さず nil")
    func truncatedSnapshotIsRejectedEntirely() {
        let payload = DropboxItemIndexSnapshot.Payload(contentVersion: 7, rows: [
            row("/a.jpg"), row("/b.jpg"), row("/c.jpg")
        ])
        let full = DropboxItemIndexSnapshot.encode(payload)
        #expect(DropboxItemIndexSnapshot.decode(full) != nil, "前提: 完全な控えは読める")
        for cut in [full.count - 1, full.count / 2, 8] {
            #expect(DropboxItemIndexSnapshot.decode(full.prefix(cut)) == nil,
                    "\(cut) バイトで切った控えから中身を返している")
        }
    }

    @Test("別のファイル・別の形式は読まない")
    func rejectsForeignData() {
        #expect(DropboxItemIndexSnapshot.decode(Data()) == nil)
        #expect(DropboxItemIndexSnapshot.decode(Data("not a snapshot at all".utf8)) == nil)
        // 形式の版が違うものは読まない（上げたら作り直す）。
        var wrong = DropboxItemIndexSnapshot.encode(.init(contentVersion: 1, rows: [row("/a.jpg")]))
        wrong[4] = 0xFE   // formatVersion の下位バイトを壊す
        #expect(DropboxItemIndexSnapshot.decode(wrong) == nil)
    }

    /// ⚠️ 余分な後ろ付きは「形式の読み違い」なので信用しない。
    @Test("余りがあるものは読まない")
    func rejectsTrailingGarbage() {
        var data = DropboxItemIndexSnapshot.encode(.init(contentVersion: 1, rows: [row("/a.jpg")]))
        data.append(contentsOf: [0x00, 0x01])
        #expect(DropboxItemIndexSnapshot.decode(data) == nil)
    }

    @Test("空の表も控えられる（写真 0 枚の端末）")
    func handlesEmptyIndex() {
        let payload = DropboxItemIndexSnapshot.Payload(contentVersion: 3, rows: [])
        #expect(DropboxItemIndexSnapshot.decode(DropboxItemIndexSnapshot.encode(payload)) == payload)
    }
}
