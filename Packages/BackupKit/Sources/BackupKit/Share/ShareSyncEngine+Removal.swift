import DropboxCore
import Foundation
import MosaicSupport

// MARK: - 消す前の確認と退避（ADR-278）
//
// 共有フォルダから消すのは、**消す理由が説明でき、中身が他に残る**ものだけ。
// 判断（どれを確かめるか・確かめた答えから何をするか）は `ShareDeletionReview`（純ロジック）、
// ここは Dropbox に訊く・移す・消すだけ。
//
// ```
// 候補 ── 分類（印からメンバーを引き当てる）
//          ├ 同じ中身がフォルダに在る ─────────────── 消す
//          ├ メンバーのコピー（置き換え先がまだ無い）── 触らない
//          └ 持ち主がいない／古い版 ── 中身が他に在るか訊く
//                                        ├ 在る ──── 消す
//                                        ├ 無い ──── ShareRemoved へ移す
//                                        └ 分からない ─ 触らない（次の回）
// ```

/// 反映 1 回ぶんの、消す前の確認に要る材料。
struct RemovalContext {
    let shareRoot: String
    /// 退避先（`<root>/<端末>/ShareRemoved`）。
    let holdingRoot: String
    /// クラウド原本の中身（パス小文字 → content_hash）。nil は「引く手段が無い」。
    let cloudHashes: [String: String]?
    let store: BackupStore
    let copier: DropboxShareCopier
    let token: String
}

extension ShareSyncEngine {

    /// 1 回の反映で片付ける「消したセットのフォルダ」の数の上限（1 つごとに確かめる往復がある）。
    static let maxRetiredFoldersPerRun = 5
    /// 消したフォルダの印を、フォルダが無くなってからも持っておく時間。発行済みのコピーが
    /// 遅れて完走してフォルダを作り直すことがある（Dropbox にジョブを取り消す API が無い）。
    static let retiredFolderGrace: TimeInterval = 24 * 60 * 60

    // MARK: - 印（消したセットのフォルダ）

    func retireFolder(_ path: String) {
        var retired = ShareSettingsKeys.retiredFolders(defaults)
        retired[path.lowercased()] = Date()
        ShareSettingsKeys.setRetiredFolders(retired, defaults)
    }

    func reviveFolder(_ path: String) {
        var retired = ShareSettingsKeys.retiredFolders(defaults)
        guard retired.removeValue(forKey: path.lowercased()) != nil else { return }
        ShareSettingsKeys.setRetiredFolders(retired, defaults)
    }

    /// **どのセットも持たないフォルダ**を片付ける（ADR-278 で規則を絞った。以前は全部消した）。
    ///
    /// ⚠️ 以前の規則は、台帳が空に見えた起動（一時的な失敗・壊れて作り直した）で
    /// **全セットのフォルダ**を消しに行く作りだった。いまは 2 種類だけを消す:
    /// - **利用者が消したセット**のフォルダ（`retiredShareFolders` に印がある）。中の写真は
    ///   1 枚ずつ、中身が他に在るかを確かめる（無ければ退避してから消す）。
    /// - 印は無いが、**中の写真が全部、いまのセットのフォルダにも在る**フォルダ（古い名前の重複）。
    ///   家族から見える写真は 1 枚も減らない。台帳が空に見える起動では「いまのセット」が無いので、
    ///   写真の入ったフォルダはこちらにも当たらない。
    /// どちらでもないフォルダは消さずに数えて出す。
    func sweepRetiredFolders(sets: [ShareSetLite], remote: RemoteShareIndex,
                             removal: RemovalContext) async {
        let wanted = Set(sets.compactMap {
            SharePlanning.setFolderPath(shareRoot: removal.shareRoot, folderName: $0.folderName,
                                        deviceFolder: nil)?.lowercased()
        })
        var retired = ShareSettingsKeys.retiredFolders(defaults)
        let before = retired
        // 同じ名前のセットがいまある＝もう消したフォルダではない。
        for path in retired.keys where wanted.contains(path) { retired.removeValue(forKey: path) }

        let holding = removal.holdingRoot.lowercased()
        let unwanted = remote.directSubfolders(of: removal.shareRoot)
            .filter { !wanted.contains($0) && $0 != holding }
            .sorted()
        // いまのセットのフォルダに在る中身（家族から見えている写真）。
        let visibleHashes = Set(wanted.flatMap { remote.photoFiles(inSetFolder: $0) }
            .compactMap(\.contentHash).filter { !$0.isEmpty })
        var budget = Self.maxRetiredFoldersPerRun
        var unknown = 0
        for folder in unwanted {
            let files = remote.filesOutsideAnalysis(under: folder)
                .map { SharePlanning.RemoteFile(pathLower: $0.pathLower, contentHash: $0.contentHash) }
            let isRetired = retired[folder] != nil
            let duplicatesOnly = files.allSatisfy { ($0.contentHash).map(visibleHashes.contains) ?? false }
            guard isRetired || duplicatesOnly else { unknown += 1; continue }
            guard budget > 0 else { break }
            budget -= 1
            let verdicts = Dictionary(uniqueKeysWithValues: files.map {
                ($0.pathLower, isRetired ? ShareDeletionReview.Verdict.needsEvidence(ownerRefKey: nil)
                                         : .duplicateOfPresent)
            })
            await removeReviewed(candidates: files, verdicts: verdicts,
                                 label: (folder as NSString).lastPathComponent,
                                 holdingFolder: (folder as NSString).lastPathComponent,
                                 baseFolder: folder, wholeFolder: folder, removal: removal)
        }
        if unknown > 0 {
            Diagnostics.mark("share sync: 持ち主の分からないフォルダ \(unknown) 個は消さない（消したセットの記録に無く、いまのセットに無い写真を含む）")
        }
        // フォルダが無くなって猶予が過ぎた印は捨てる。
        let present = Set(unwanted)
        let now = Date()
        for (path, at) in retired where !present.contains(path)
            && now.timeIntervalSince(at) > Self.retiredFolderGrace {
            retired.removeValue(forKey: path)
        }
        if retired != before { ShareSettingsKeys.setRetiredFolders(retired, defaults) }
    }

    // MARK: - 確かめて、移して、消す

    /// 分類済みの候補を片付ける。
    /// - Parameters:
    ///   - holdingFolder: 退避先の下に作るフォルダ名（セットのフォルダ名）。
    ///   - baseFolder: 候補のパスの基準。退避先では、ここからの相対パスを保つ。
    ///   - wholeFolder: 消したセットのフォルダ。**全部を片付けられた回だけ**フォルダごと消す。
    func removeReviewed(candidates: [SharePlanning.RemoteFile],
                        verdicts: [String: ShareDeletionReview.Verdict],
                        label: String, holdingFolder: String, baseFolder: String,
                        wholeFolder: String?,
                        removal: RemovalContext) async {
        let evidenceByHash = await gatherEvidence(candidates: candidates, verdicts: verdicts,
                                                  removal: removal)
        var deletes: [String] = []
        var moves: [SharePlanning.RemoteFile] = []
        var keptForMember = 0
        var undecided = 0
        for candidate in candidates.sorted(by: { $0.pathLower < $1.pathLower }) {
            let verdict = verdicts[candidate.pathLower] ?? .deferred
            let evidence = candidate.contentHash.flatMap { evidenceByHash[$0] }
            switch ShareDeletionReview.action(for: verdict, evidence: evidence) {
            case .delete: deletes.append(candidate.pathLower)
            case .moveToHolding: moves.append(candidate)
            case .leave:
                if case .keptForMember = verdict { keptForMember += 1 } else { undecided += 1 }
            }
        }

        // 退避（1 枚ずつ・上限は削除と同じ）。
        var moved = 0
        var moveFailed = 0
        for file in moves.prefix(Self.maxDeletesPerRun) {
            let prefix = baseFolder.lowercased() + "/"
            let relative = file.pathLower.hasPrefix(prefix)
                ? String(file.pathLower.dropFirst(prefix.count))
                : (file.pathLower as NSString).lastPathComponent
            let destination = "\(removal.holdingRoot)/\(holdingFolder)/\(relative)"
            if await removal.copier.moveToHolding(from: file.pathLower, to: destination,
                                                  token: removal.token) {
                moved += 1
            } else {
                moveFailed += 1
            }
        }
        let movesLeft = moves.count - moved

        if let wholeFolder, keptForMember == 0, undecided == 0, movesLeft == 0 {
            // 中の写真は全部「他に在る」か「退避した」——フォルダごと消してよい（解析データも一緒に）。
            BackupLogger.info("Share sync: removing retired folder '\(label)'")
            _ = await removal.copier.deleteBatch(paths: [wholeFolder], token: removal.token)
        } else if !deletes.isEmpty {
            let budget = Array(deletes.prefix(Self.maxDeletesPerRun))
            BackupLogger.info("Share sync: '\(label)' deleting \(budget.count) stale file(s)")
            _ = await removal.copier.deleteBatch(paths: budget, token: removal.token)
        }

        if moved > 0 {
            Diagnostics.mark("share: '\(label)' 中身が Dropbox のどこにも無い \(moved) 枚を "
                             + "\(BackupLayout.shareRemovedSubfolder) へ退避（消さずに残す）")
        }
        if keptForMember > 0 || undecided > 0 || moveFailed > 0 {
            // ⚠️ 黙って残さない（「消えないのにログが無い」を作らない）。
            Diagnostics.mark("share: '\(label)' 消す前の確認で残した \(keptForMember + undecided + moveFailed) 枚"
                             + "（メンバーのコピー \(keptForMember)・確かめきれない \(undecided)・"
                             + "退避の失敗 \(moveFailed)）")
        }
    }

    /// 「持ち主がいない／古い版」の候補について、中身が Dropbox の他の場所に在るかを訊く。
    /// - Returns: 中身 → 証拠。**訊かなかった中身は入れない**（＝分からない）。
    private func gatherEvidence(candidates: [SharePlanning.RemoteFile],
                                verdicts: [String: ShareDeletionReview.Verdict],
                                removal: RemovalContext) async -> [String: ShareDeletionReview.Evidence] {
        var hashes = Set<String>()
        for candidate in candidates {
            guard case .needsEvidence = verdicts[candidate.pathLower],
                  let hash = candidate.contentHash, !hash.isEmpty else { continue }
            hashes.insert(hash)
        }
        guard !hashes.isEmpty else { return [:] }
        // ⚠️ 記録が読めなければ**全部「分からない」**（「どこにも無い」と読んで退避しない）。
        guard let records = await removal.store.backupPaths(withContentHashes: hashes) else {
            Diagnostics.mark("share: 消す前の確認でバックアップ記録が読めない — この回は消さない")
            return Dictionary(uniqueKeysWithValues: hashes.map { ($0, .unknown) })
        }
        let locations = ShareDeletionReview.locations(
            for: hashes, records: records, cloud: removal.cloudHashes ?? [:],
            excludingPrefixes: [removal.shareRoot, removal.holdingRoot])
        let plan = ShareDeletionReview.verificationPlan(locations: locations)

        var answers: [String: ShareDeletionReview.Lookup] = [:]
        let wantedPaths = Set(locations.values.joined())
        for folder in plan.listFolders {
            let inFolder = wantedPaths.filter { ($0 as NSString).deletingLastPathComponent == folder }
            guard let listed = await removal.copier.listFolder(path: folder, token: removal.token) else {
                for path in inFolder { answers[path] = .failed }
                continue
            }
            let found = Dictionary(listed.filter { !$0.isFolder }.map { ($0.pathLower, $0.contentHash) },
                                   uniquingKeysWith: { first, _ in first })
            for path in inFolder {
                if let hash = found[path] { answers[path] = .file(contentHash: hash) } else { answers[path] = .notFound }
            }
        }
        for path in plan.metadataPaths {
            answers[path] = await removal.copier.lookup(path: path, token: removal.token)
        }
        return Dictionary(uniqueKeysWithValues: hashes.map {
            ($0, ShareDeletionReview.evidence(for: $0, locations: locations, answers: answers))
        })
    }
}
