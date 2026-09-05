#if canImport(UIKit)
import DropboxKit
import Foundation
import PerceptionCore
import Testing
@testable import PhotosFeatureKit

/// 解析候補からバックアップコピーを外す（実フィードバック「ピープルの分母がじわじわ上がる」）。
/// 表示の重複排除（`BackupCopyHiding`）と同じ規則で、端末に原本があるコピーだけを外す。
@Suite("AnalysisCandidates.hiddenBackupCopyRefKeys", .serialized)
@MainActor
struct AnalysisCandidatesTests {
    private func item(_ path: String) -> DropboxFileItem {
        DropboxFileItem(path: path, name: (path as NSString).lastPathComponent)
    }

    @Test("端末に原本があるコピーだけ外す。原本が無い（オフロード済み）コピーは残す")
    func hidesOnlyCopiesWhoseOriginalExists() async {
        let previous = AnalysisCandidates.backupCopyIndexProvider
        defer { AnalysisCandidates.backupCopyIndexProvider = previous }
        AnalysisCandidates.backupCopyIndexProvider = {
            ["/mosaicphotos/iphone-x/backup/2024/2024-03/img_1.jpg": BackupCopyInfo(localIdentifier: "L1", captureDate: nil),
             "/mosaicphotos/iphone-x/backup/2024/2024-03/img_2.jpg": BackupCopyInfo(localIdentifier: "L2-offloaded", captureDate: nil)]
        }
        let cloud = [item("/MosaicPhotos/iPhone-X/Backup/2024/2024-03/IMG_1.jpg"),   // 原本 L1 あり → 外す
                     item("/MosaicPhotos/iPhone-X/Backup/2024/2024-03/IMG_2.jpg"),   // 原本なし → 残す
                     item("/Camera Uploads/other.jpg")]                              // 台帳外 → 残す
        let hidden = await AnalysisCandidates.hiddenBackupCopyRefKeys(
            cloudItems: cloud, localRefKeys: [PhotoRef.local("L1").encoded])
        #expect(hidden == [PhotoRef.cloud("/MosaicPhotos/iPhone-X/Backup/2024/2024-03/IMG_1.jpg").encoded])
    }

    @Test("自分の共有ルート配下は台帳に関係なく外す（原本と解析結果はバックアップにある）")
    func excludesOwnShareRoot() async {
        let previousIndex = AnalysisCandidates.backupCopyIndexProvider
        let previousPrefixes = AnalysisCandidates.excludedCloudPathPrefixes
        defer {
            AnalysisCandidates.backupCopyIndexProvider = previousIndex
            AnalysisCandidates.excludedCloudPathPrefixes = previousPrefixes
        }
        AnalysisCandidates.backupCopyIndexProvider = nil
        AnalysisCandidates.excludedCloudPathPrefixes = ["/mosaicphotos/iphone-x/share"]
        let cloud = [item("/MosaicPhotos/iPhone-X/Share/People-Family/IMG_9.jpg"),   // 共有コピー → 外す
                     item("/MosaicPhotos/iPhone-X/Share"),                            // ルートそのもの → 外す
                     item("/MosaicPhotos/iPhone-X/Sharework/x.jpg"),                  // 接頭辞が似ているだけ → 残す
                     item("/MosaicPhotos/iPhone-X/Backup/2024/2024-03/IMG_2.jpg")]    // 台帳なし → 残す
        let hidden = await AnalysisCandidates.hiddenBackupCopyRefKeys(cloudItems: cloud, localRefKeys: [])
        #expect(hidden == [PhotoRef.cloud("/MosaicPhotos/iPhone-X/Share/People-Family/IMG_9.jpg").encoded,
                           PhotoRef.cloud("/MosaicPhotos/iPhone-X/Share").encoded])
    }

    @Test("台帳が未結線・空なら何も隠さない（分からないものは隠さない）")
    func hidesNothingWithoutLedger() async {
        let previous = AnalysisCandidates.backupCopyIndexProvider
        defer { AnalysisCandidates.backupCopyIndexProvider = previous }
        let previousPrefixes = AnalysisCandidates.excludedCloudPathPrefixes
        defer { AnalysisCandidates.excludedCloudPathPrefixes = previousPrefixes }
        AnalysisCandidates.backupCopyIndexProvider = nil
        AnalysisCandidates.excludedCloudPathPrefixes = []
        let hidden = await AnalysisCandidates.hiddenBackupCopyRefKeys(
            cloudItems: [item("/x.jpg")], localRefKeys: [PhotoRef.local("L1").encoded])
        #expect(hidden.isEmpty)
    }
}
#endif
