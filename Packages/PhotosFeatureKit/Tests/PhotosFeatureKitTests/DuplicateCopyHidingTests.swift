#if canImport(UIKit)
import DropboxKit
import Foundation
import PerceptionCore
import Testing
@testable import PhotosFeatureKit

/// 同じ Dropbox の他の端末の共有コピー（同じ中身が相手の Backup にもある）を 1 枚にする（ADR-276）。
///
/// ⚠️ 要点は「**残す方がその画面に出るときだけ隠す**」。受け取ったアルバムは共有コピーだけを
/// メンバーに持つので、無条件に隠すとアルバムが空になる。
@Suite("重複コピーの隠し方（BackupCopyHiding.hiddenDuplicates）", .serialized)
@MainActor
struct DuplicateCopyHidingTests {
    private let share = "/MosaicPhotos/iPhone-B/Share/Trip/b1.jpg"
    private let backup = "/MosaicPhotos/iPhone-B/Backup/2020/2020-09/b1.jpg"

    private var index: [String: BackupCopyInfo] {
        [share.lowercased(): BackupCopyInfo(localIdentifier: nil, captureDate: nil,
                                            duplicateOf: backup.lowercased())]
    }

    @Test("絞り込みの無い画面（すべての写真）では、共有コピーを隠す")
    func hiddenWithoutFilter() {
        #expect(BackupCopyHiding.hiddenDuplicates(backupCopies: index, visiblePaths: nil) == [share.lowercased()])
    }

    @Test("残す方が出ない画面（受け取ったアルバム）では隠さない／残す方も出るなら隠す")
    func keptCopyMustBeVisible() {
        #expect(BackupCopyHiding.hiddenDuplicates(backupCopies: index,
                                                  visiblePaths: [share.lowercased()]).isEmpty,
                "受け取ったアルバムから写真が消える")
        #expect(BackupCopyHiding.hiddenDuplicates(backupCopies: index,
                                                  visiblePaths: [share.lowercased(), backup.lowercased()])
                == [share.lowercased()])
    }

    @Test("重複でない記録（duplicateOf が無い）は隠す理由にならない")
    func plainRecordsAreNotDuplicates() {
        let plain = [backup.lowercased(): BackupCopyInfo(localIdentifier: nil, captureDate: nil)]
        #expect(BackupCopyHiding.hiddenDuplicates(backupCopies: plain, visiblePaths: nil).isEmpty)
    }

    @Test("統合一覧: すべての写真では 1 枚、受け取ったアルバム（共有コピーだけ）では残る")
    func mergedListKeepsAlbumMembers() {
        let items = [DropboxFileItem(path: share, name: "b1.jpg"), DropboxFileItem(path: backup, name: "b1.jpg")]
        let all = Self.visible(items, filter: nil, index: index)
        #expect(all == [backup], "すべての写真で 2 枚に見える: \(all)")
        let album = Self.visible(items, filter: [share], index: index)
        #expect(album == [share], "受け取ったアルバムが空になった")
    }

    /// `MergedPhotoStore.rebuildItems` と同じ組み立て（隠す集合 → `appendVisibleCloudItems`）。
    private static func visible(_ items: [DropboxFileItem], filter: Set<String>?,
                                index: [String: BackupCopyInfo]) -> [String] {
        var hidden = BackupCopyHiding.hiddenPaths(backupCopies: index, localIdentifiers: [])
        hidden.formUnion(BackupCopyHiding.hiddenDuplicates(
            backupCopies: index, visiblePaths: filter.map { Set($0.map { $0.lowercased() }) }))
        var merged: [MergedPhotoItem] = []
        MergedPhotoStore.appendVisibleCloudItems(items, filter: filter, hidden: hidden,
                                                 backupIndex: index, to: &merged)
        return merged.compactMap { if case .cloud(let item) = $0 { return item.path } else { return nil } }
    }

    @Test("解析の候補からも外す（残す方を解析する）")
    func analysisCandidatesSkipDuplicates() async {
        let previous = AnalysisCandidates.backupCopyIndexProvider
        let previousPrefixes = AnalysisCandidates.excludedCloudPathPrefixes
        defer {
            AnalysisCandidates.backupCopyIndexProvider = previous
            AnalysisCandidates.excludedCloudPathPrefixes = previousPrefixes
        }
        let index = index
        AnalysisCandidates.backupCopyIndexProvider = { index }
        AnalysisCandidates.excludedCloudPathPrefixes = []
        let hidden = await AnalysisCandidates.hiddenBackupCopyRefKeys(
            cloudItems: [CloudPhotoRef(path: share, captureDate: nil), CloudPhotoRef(path: backup, captureDate: nil)],
            localRefKeys: [])
        #expect(hidden == [PhotoRef.cloud(share).encoded])
    }
}
#endif
