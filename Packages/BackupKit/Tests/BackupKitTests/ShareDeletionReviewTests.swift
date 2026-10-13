import Foundation
import Testing
@testable import BackupKit

/// **消す前の確認**（`ShareDeletionReview`・ADR-278）の純ロジック。
///
/// 規則そのものの正しさをここで見る。「材料が欠けた回に、本当に消えないか」は
/// `ShareDeletionSafetyTests`（偽 Dropbox で通す）が見る。
@Suite("消す前の確認（純ロジック・ADR-278）")
struct ShareDeletionReviewTests {

    private let folder = "/root/dev/share/trip"

    /// テストが実装と同じ規則で名前を組む。
    private func path(_ refKey: String, hash: String?, name: String = "IMG.jpg") -> String {
        let identity = ShareNaming.identity(refKey: refKey, contentHash: hash)
        return "\(folder)/\(ShareNaming.sharedFileName(sourceFileName: name, identity: identity))".lowercased()
    }

    private func file(_ path: String, _ hash: String?) -> SharePlanning.RemoteFile {
        .init(pathLower: path, contentHash: hash)
    }

    // MARK: - 分類

    @Test("同じ中身がフォルダに在るものは消してよい")
    func duplicateOfPresentIsDeletable() {
        let stale = path("C-/x.jpg", hash: nil)   // 中身が分からなかった頃の名前
        let verdicts = ShareDeletionReview.classify(
            candidates: [file(stale, "h1")], members: ["C-/x.jpg"],
            destinationByRefKey: ["C-/x.jpg": path("C-/x.jpg", hash: "h1")],
            presentAfterCopy: [path("C-/x.jpg", hash: "h1")], presentHashes: ["h1"])
        #expect(verdicts[stale] == .duplicateOfPresent)
    }

    @Test("メンバーがまだ解決できない（記録が消えた）コピーは触らない")
    func unresolvedMembersCopyIsKept() {
        let copy = path("L-p0", hash: "h0")
        let verdicts = ShareDeletionReview.classify(
            candidates: [file(copy, "h0")], members: ["L-p0"],
            destinationByRefKey: [:], presentAfterCopy: [], presentHashes: [])
        #expect(verdicts[copy] == .keptForMember(refKey: "L-p0"))
    }

    @Test("中身が分からない名前で置いたコピーも、メンバーのものと分かる")
    func hashlessIdentityIsRecognized() {
        let copy = path("C-/x.jpg", hash: nil)
        let verdicts = ShareDeletionReview.classify(
            candidates: [file(copy, "h9")], members: ["C-/x.jpg"],
            destinationByRefKey: [:], presentAfterCopy: [], presentHashes: [])
        #expect(verdicts[copy] == .keptForMember(refKey: "C-/x.jpg"))
    }

    @Test("新しい版のコピーがまだ無ければ、古い版は触らない／在れば確かめに回す")
    func oldVersionWaitsForReplacement() {
        let old = path("L-p1", hash: "h1")
        let new = path("L-p1", hash: "h1v2")
        let waiting = ShareDeletionReview.classify(
            candidates: [file(old, "h1")], members: ["L-p1"],
            destinationByRefKey: ["L-p1": new], presentAfterCopy: [], presentHashes: [])
        #expect(waiting[old] == .keptForMember(refKey: "L-p1"))

        let replaced = ShareDeletionReview.classify(
            candidates: [file(old, "h1")], members: ["L-p1"],
            destinationByRefKey: ["L-p1": new], presentAfterCopy: [new], presentHashes: ["h1v2"])
        #expect(replaced[old] == .needsEvidence(ownerRefKey: "L-p1"))
    }

    @Test("持ち主のいないコピー・印の無い名前は確かめに回す")
    func unownedNeedsEvidence() {
        let removed = path("L-gone", hash: "hg")
        let legacy = "\(folder)/img_0001.jpg"
        let verdicts = ShareDeletionReview.classify(
            candidates: [file(removed, "hg"), file(legacy, "hl")], members: ["L-p0"],
            destinationByRefKey: [:], presentAfterCopy: [], presentHashes: [])
        #expect(verdicts[removed] == .needsEvidence(ownerRefKey: nil))
        #expect(verdicts[legacy] == .needsEvidence(ownerRefKey: nil))
    }

    @Test("照合の上限を超えた候補は持ち越す（確かめずに消さない）")
    func overBudgetIsDeferred() {
        let members = (0..<10).map { "L-m\($0)" }
        let candidates = (0..<3).map { file(path("L-gone\($0)", hash: "g\($0)"), "g\($0)") }
        // 中身の分からない表（10）＋ 1 つ目の中身（10）で使い切る上限。
        let verdicts = ShareDeletionReview.classify(
            candidates: candidates, members: members, destinationByRefKey: [:],
            presentAfterCopy: [], presentHashes: [], hashBudget: 20)
        let sorted = candidates.map(\.pathLower).sorted()
        #expect(verdicts[sorted[0]] == .needsEvidence(ownerRefKey: nil))
        #expect(verdicts[sorted[1]] == .deferred)
        #expect(verdicts[sorted[2]] == .deferred)
    }

    // MARK: - やること

    @Test("証拠ごとのやること（無い→退避・分からない→触らない）")
    func actionTable() {
        typealias R = ShareDeletionReview
        #expect(R.action(for: .duplicateOfPresent, evidence: nil) == .delete)
        #expect(R.action(for: .keptForMember(refKey: "x"), evidence: .foundElsewhere) == .leave)
        #expect(R.action(for: .deferred, evidence: .foundElsewhere) == .leave)
        #expect(R.action(for: .needsEvidence(ownerRefKey: nil), evidence: .foundElsewhere) == .delete)
        #expect(R.action(for: .needsEvidence(ownerRefKey: nil), evidence: .absentEverywhere) == .moveToHolding)
        #expect(R.action(for: .needsEvidence(ownerRefKey: nil), evidence: .unknown) == .leave)
        #expect(R.action(for: .needsEvidence(ownerRefKey: nil), evidence: nil) == .leave)
    }

    // MARK: - どこを確かめるか

    @Test("共有のコピーと退避先は証拠にしない（2 台が互いを当てにして両方消さない）")
    func shareCopiesAreNotEvidence() {
        let shareCopy = path("L-p0", hash: "h0")
        let locations = ShareDeletionReview.locations(
            for: ["h0"],
            records: [(path: "/root/dev/backup/2020/p0.jpg", hash: "h0")],
            cloud: [shareCopy: "h0",
                    "/root/other/share/trip/p0--abcdef0123.jpg": "h0",
                    "/root/dev/shareremoved/trip/x.jpg": "h0",
                    "/camera uploads/p0.jpg": "h0"],
            excludingPrefixes: ["/root/dev/share", "/root/dev/ShareRemoved"])
        #expect(locations["h0"] == ["/camera uploads/p0.jpg", "/root/dev/backup/2020/p0.jpg"])
    }

    @Test("多い親フォルダは一覧 1 回、少なければ 1 件ずつ・往復の上限を守る")
    func verificationPlanGroupsByParent() {
        let many = (0..<ShareDeletionReview.listThreshold).map { "/b/2020/p\($0).jpg" }
        let plan = ShareDeletionReview.verificationPlan(
            locations: ["h": many, "k": ["/c/x.jpg", "/c/y.jpg"]])
        #expect(plan.listFolders == ["/b/2020"])
        #expect(plan.metadataPaths == ["/c/x.jpg", "/c/y.jpg"])

        let capped = ShareDeletionReview.verificationPlan(
            locations: ["k": ["/c/x.jpg", "/c/y.jpg"], "m": ["/d/z.jpg"]], maxRequests: 2)
        #expect(capped.metadataPaths == ["/c/x.jpg", "/c/y.jpg"], "上限を超えて訊いた")
    }

    @Test("証拠: 同じ中身が在れば在る・全部訊いて無ければ無い・訊けなければ分からない")
    func evidenceFromAnswers() {
        typealias R = ShareDeletionReview
        let locations = ["h": ["/a.jpg", "/b.jpg"]]
        #expect(R.evidence(for: "h", locations: locations,
                           answers: ["/a.jpg": .notFound, "/b.jpg": .file(contentHash: "h")]) == .foundElsewhere)
        #expect(R.evidence(for: "h", locations: locations,
                           answers: ["/a.jpg": .notFound, "/b.jpg": .file(contentHash: "other")]) == .absentEverywhere)
        #expect(R.evidence(for: "h", locations: locations,
                           answers: ["/a.jpg": .notFound, "/b.jpg": .failed]) == .unknown)
        #expect(R.evidence(for: "h", locations: locations, answers: ["/a.jpg": .notFound]) == .unknown,
                "訊いていない場所を「無い」と読んだ")
        #expect(R.evidence(for: "h", locations: [:], answers: [:]) == .absentEverywhere)
    }

    // MARK: - 計画: 中身の分からないクラウド写真

    @Test("中身を引く手段があるのに分からないクラウド写真は、この回はコピーしない")
    func unknownCloudHashWaits() {
        let items = [ShareItemLite(refKey: "C-/x.jpg", addedAt: Date())]
        let known = SharePlanning.plan(items: items, backupByLocalID: [:],
                                       cloudHashByPath: ["/x.jpg": "h"], setFolder: folder,
                                       remoteFiles: [])
        #expect(known.copies.count == 1)
        let unknown = SharePlanning.plan(items: items, backupByLocalID: [:],
                                         cloudHashByPath: [:], setFolder: folder, remoteFiles: [])
        #expect(unknown.copies.isEmpty, "中身が分からないまま別の名前でコピーした")
        #expect(unknown.waitingCloudHash == ["C-/x.jpg"])
        // 手段が無い（nil）なら従来どおり refKey だけで名前を決める。
        let legacy = SharePlanning.plan(items: items, backupByLocalID: [:],
                                        cloudHashByPath: nil, setFolder: folder, remoteFiles: [])
        #expect(legacy.copies.count == 1)
    }
}
