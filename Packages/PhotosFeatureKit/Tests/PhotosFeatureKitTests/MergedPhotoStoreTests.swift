import Testing
@testable import PhotosFeatureKit

// MARK: - バックアップコピーの二重表示（実機 diagnostics-57/58）

/// ⚠️ バックアップフォルダは**意図的に**同期対象に入っている（オフロード写真のクラウド代替）。
/// ところが統合一覧に重複排除が無く、**端末に原本が有る写真まで二重に出ていた**。
/// バックアップが古い写真を上げ進めるほど古い写真が次々に現れる、という見え方になっていた。
@Suite("バックアップコピーの隠蔽")
struct BackupCopyHidingTests {

    private let index = ["/mosaicphotos/img_0001.jpg": "LOCAL-1",
                         "/mosaicphotos/img_0002.jpg": "LOCAL-2"]

    @Test("端末に原本が有るコピーは隠す")
    func hidesWhenOriginalExists() {
        let hidden = BackupCopyHiding.hiddenPaths(backupPathToLocalID: index,
                                                  localIdentifiers: ["LOCAL-1"])
        #expect(hidden == ["/mosaicphotos/img_0001.jpg"], "1 枚の写真が二重に並ぶ")
    }

    /// オフロード（端末から消した）写真は、クラウドのコピーが**唯一の実体**。
    @Test("端末に原本が無いコピーは残す")
    func keepsWhenOriginalIsGone() {
        let hidden = BackupCopyHiding.hiddenPaths(backupPathToLocalID: index,
                                                  localIdentifiers: ["LOCAL-1"])
        #expect(!hidden.contains("/mosaicphotos/img_0002.jpg"),
                "オフロード済みの写真が一覧から消える")
    }

    /// 隠して「無い」と思わせるのは取り返しがつかない。分からないなら重複させる方を選ぶ。
    @Test("対応が分からなければ何も隠さない")
    func unknownMappingHidesNothing() {
        #expect(BackupCopyHiding.hiddenPaths(backupPathToLocalID: [:],
                                             localIdentifiers: ["LOCAL-1"]).isEmpty)
        #expect(BackupCopyHiding.hiddenPaths(backupPathToLocalID: index,
                                             localIdentifiers: []).isEmpty)
    }

    @Test("台帳に無いクラウド写真は対象外")
    func unrelatedCloudPhotosAreUntouched() {
        let hidden = BackupCopyHiding.hiddenPaths(backupPathToLocalID: index,
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

    private func signature(_ ids: [String]) -> Int {
        var hasher = Hasher()
        for id in ids { hasher.combine(id) }
        hasher.combine(ids.count)
        return hasher.finalize()
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
}
