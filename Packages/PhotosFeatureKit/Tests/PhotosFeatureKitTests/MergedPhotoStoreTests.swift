import Foundation
import Testing
import DropboxKit
@testable import PhotosFeatureKit

// MARK: - バックアップコピーの二重表示（実機 diagnostics-57/58）

/// ⚠️ バックアップフォルダは**意図的に**同期対象に入っている（オフロード写真のクラウド代替）。
/// ところが統合一覧に重複排除が無く、**端末に原本が有る写真まで二重に出ていた**。
/// バックアップが古い写真を上げ進めるほど古い写真が次々に現れる、という見え方になっていた。
@Suite("バックアップコピーの隠蔽")
struct BackupCopyHidingTests {

    /// 台帳の索引（本番と同じ型）。⚠️ `[String: String]` を受ける版は畳んだので、
    /// テストも本番と同じ `BackupCopyInfo` を渡す（レビュー 9 周目）。
    private let index = [
        "/mosaicphotos/img_0001.jpg": BackupCopyInfo(localIdentifier: "LOCAL-1", captureDate: nil),
        "/mosaicphotos/img_0002.jpg": BackupCopyInfo(localIdentifier: "LOCAL-2", captureDate: nil),
    ]

    @Test("端末に原本が有るコピーは隠す")
    func hidesWhenOriginalExists() {
        let hidden = BackupCopyHiding.hiddenPaths(backupCopies: index,
                                                  localIdentifiers: ["LOCAL-1"])
        #expect(hidden == ["/mosaicphotos/img_0001.jpg"], "1 枚の写真が二重に並ぶ")
    }

    /// オフロード（端末から消した）写真は、クラウドのコピーが**唯一の実体**。
    @Test("端末に原本が無いコピーは残す")
    func keepsWhenOriginalIsGone() {
        let hidden = BackupCopyHiding.hiddenPaths(backupCopies: index,
                                                  localIdentifiers: ["LOCAL-1"])
        #expect(!hidden.contains("/mosaicphotos/img_0002.jpg"),
                "オフロード済みの写真が一覧から消える")
    }

    /// 隠して「無い」と思わせるのは取り返しがつかない。分からないなら重複させる方を選ぶ。
    @Test("対応が分からなければ何も隠さない")
    func unknownMappingHidesNothing() {
        #expect(BackupCopyHiding.hiddenPaths(backupCopies: [:],
                                             localIdentifiers: ["LOCAL-1"]).isEmpty)
        #expect(BackupCopyHiding.hiddenPaths(backupCopies: index,
                                             localIdentifiers: []).isEmpty)
    }

    @Test("台帳に無いクラウド写真は対象外")
    func unrelatedCloudPhotosAreUntouched() {
        let hidden = BackupCopyHiding.hiddenPaths(backupCopies: index,
                                                  localIdentifiers: ["LOCAL-1", "LOCAL-2"])
        #expect(!hidden.contains("/写真/family/old.jpg"))
        #expect(hidden.count == 2)
    }
}

// MARK: - 同じ内容なら差し替えない（実機 diagnostics-59）

/// ⚠️ 同期中は 0.4 秒ごとに再構築が走るが、内容は変わらないことがほとんど。
/// それでも代入すると配列の実体が変わり、グリッドは「変わったかもしれない」として
/// 86,000 件ぶんの ID 指紋を**メインで**取り直す（id は文字列を作り、その中で
/// PHAsset.localIdentifier まで読む）。指紋で素通しさせる。
@Suite("統合一覧の指紋")
struct MergedSignatureTests {

    /// ⚠️ **本番と同じ関数を呼ぶ**（レビュー指摘）。以前はここに式を書き写していたので、
    /// 本番の指紋に撮影日を足しても気づかず、**その行を消しても緑のまま**だった。
    private func signature(_ ids: [String], dates: [Date?]? = nil) -> Int {
        MergedPhotoStore.signature(of: ids.enumerated().map { index, id in
            .cloud(DropboxFileItem(path: id, name: id,
                                   captureDate: dates.flatMap { $0.indices.contains(index) ? $0[index] : nil }))
        })
    }

    @Test("同じ並びなら同じ指紋")
    func sameOrderSameSignature() {
        #expect(signature(["L-1", "C-2"]) == signature(["L-1", "C-2"]))
    }

    @Test("並びが変われば違う指紋")
    func orderMatters() {
        #expect(signature(["L-1", "C-2"]) != signature(["C-2", "L-1"]),
                "並び替えを取りこぼすと別の写真が表示される")
    }

    @Test("件数が同じでも中身が入れ替われば違う指紋")
    func swappedMemberDetected() {
        #expect(signature(["L-1", "C-2"]) != signature(["L-1", "C-3"]))
    }

    @Test("長さも混ぜる（前方一致を取り違えない）")
    func lengthIsMixedIn() {
        #expect(signature(["L-1"]) != signature(["L-1", "L-2"]))
    }

    /// 回帰: **並び順が同じでも撮影日が直れば別の指紋**（ADR-199）。
    /// 共有フォルダは撮影順にアップロードされることが多いので、受け取った撮影日を
    /// 反映しても並びは変わらない——指紋が同じだと代入が飛ばされ、月の見出しと
    /// 情報パネルがアップロード時刻のまま残る（開き直すまで直らない）。
    @Test("並びが同じでも撮影日が変われば違う指紋")
    func captureDateIsMixedIn() {
        // ⚠️ どちらも**過去**の日付にする（レビュー指摘）。以前は反映時刻側に
        // 2027 年を使っていたが、`DropboxFileItem.init` は `CaptureDate.meaningful`
        // （上限＝今から 2 日後）で未来を nil に落とすので、**nil と日付**を比べていた
        // ——「反映時刻 vs 撮影日」という、このテストが名乗る条件を試していなかった。
        // しかも 2027-01-13 を過ぎると黙って別の条件に変わる。
        let uploaded = Date(timeIntervalSince1970: 1_700_000_000)   // 反映時刻（2023-11）
        let taken    = Date(timeIntervalSince1970: 1_000_000_000)   // 本当の撮影日（2001-09）
        let before = signature(["C-/f/a.jpg", "C-/f/b.jpg"], dates: [uploaded, uploaded])
        let after  = signature(["C-/f/a.jpg", "C-/f/b.jpg"], dates: [taken, taken])
        #expect(before != after,
                "撮影日だけが直った更新を取りこぼす＝ADR-199 がいちばん効く場面で反映されない")
    }

    /// 撮影日の**有無**だけを見る実装（`captureDate != nil` を混ぜる等）に退行させない。
    /// ⚠️ 以前はここが `signature(x) == signature(x)` で、何も検証していなかった。
    @Test("撮影日は有無ではなく値そのものが効く")
    func captureDateValueMattersNotJustPresence() {
        let early = signature(["C-/f/a.jpg"], dates: [Date(timeIntervalSince1970: 1_000_000_000)])
        let late  = signature(["C-/f/a.jpg"], dates: [Date(timeIntervalSince1970: 1_700_000_000)])
        let none  = signature(["C-/f/a.jpg"], dates: [nil])
        #expect(early != late, "日付の値が効いていない（有無しか見ていない）")
        #expect(early != none)
    }
}
