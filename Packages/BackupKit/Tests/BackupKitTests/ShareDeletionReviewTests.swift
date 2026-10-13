import CryptoKit
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
            candidates: [file(stale, "h1")], members: ["C-/x.jpg"], sourceFileNames: [:],
            destinationByRefKey: ["C-/x.jpg": path("C-/x.jpg", hash: "h1")],
            presentAfterCopy: [path("C-/x.jpg", hash: "h1")], presentHashes: ["h1"], startOffset: 0)
        #expect(verdicts[stale] == .duplicateOfPresent)
    }

    @Test("メンバーがまだ解決できない（記録が消えた）コピーは触らない")
    func unresolvedMembersCopyIsKept() {
        let copy = path("L-p0", hash: "h0")
        let verdicts = ShareDeletionReview.classify(
            candidates: [file(copy, "h0")], members: ["L-p0"], sourceFileNames: [:],
            destinationByRefKey: [:], presentAfterCopy: [], presentHashes: [], startOffset: 0)
        #expect(verdicts[copy] == .keptForMember(refKey: "L-p0"))
    }

    @Test("中身が分からない名前で置いたコピーも、メンバーのものと分かる")
    func hashlessIdentityIsRecognized() {
        let copy = path("C-/x.jpg", hash: nil)
        let verdicts = ShareDeletionReview.classify(
            candidates: [file(copy, "h9")], members: ["C-/x.jpg"], sourceFileNames: [:],
            destinationByRefKey: [:], presentAfterCopy: [], presentHashes: [], startOffset: 0)
        #expect(verdicts[copy] == .keptForMember(refKey: "C-/x.jpg"))
    }

    @Test("新しい版のコピーがまだ無ければ、古い版は触らない／在れば確かめに回す")
    func oldVersionWaitsForReplacement() {
        let old = path("L-p1", hash: "h1")
        let new = path("L-p1", hash: "h1v2")
        let waiting = ShareDeletionReview.classify(
            candidates: [file(old, "h1")], members: ["L-p1"], sourceFileNames: [:],
            destinationByRefKey: ["L-p1": new], presentAfterCopy: [], presentHashes: [], startOffset: 0)
        #expect(waiting[old] == .keptForMember(refKey: "L-p1"))

        let replaced = ShareDeletionReview.classify(
            candidates: [file(old, "h1")], members: ["L-p1"], sourceFileNames: [:],
            destinationByRefKey: ["L-p1": new], presentAfterCopy: [new], presentHashes: ["h1v2"], startOffset: 0)
        #expect(replaced[old] == .needsEvidence(ownerRefKey: "L-p1"))
    }

    @Test("持ち主のいないコピー・印の無い名前は確かめに回す")
    func unownedNeedsEvidence() {
        let removed = path("L-gone", hash: "hg")
        let legacy = "\(folder)/img_0001.jpg"
        let verdicts = ShareDeletionReview.classify(
            candidates: [file(removed, "hg"), file(legacy, "hl")], members: ["L-p0"], sourceFileNames: [:],
            destinationByRefKey: [:], presentAfterCopy: [], presentHashes: [], startOffset: 0)
        #expect(verdicts[removed] == .needsEvidence(ownerRefKey: nil))
        #expect(verdicts[legacy] == .needsEvidence(ownerRefKey: nil))
    }

    @Test("照合の上限を超えた候補は持ち越す（確かめずに消さない）")
    func overBudgetIsDeferred() {
        let members = (0..<10).map { "L-m\($0)" }
        let candidates = (0..<3).map { file(path("L-gone\($0)", hash: "g\($0)"), "g\($0)") }
        // 元の名前が分からないメンバー 10 人 × 2 通りの印（中身あり／なし）で 1 候補ぶんの上限。
        let verdicts = ShareDeletionReview.classify(
            candidates: candidates, members: members, sourceFileNames: [:], destinationByRefKey: [:],
            presentAfterCopy: [], presentHashes: [], startOffset: 0, hashBudget: 20)
        let sorted = candidates.map(\.pathLower).sorted()
        #expect(verdicts[sorted[0]] == .needsEvidence(ownerRefKey: nil))
        #expect(verdicts[sorted[1]] == .deferred)
        #expect(verdicts[sorted[2]] == .deferred)
    }

    @Test("照合はファイル名の幹で絞る（メンバー数 × 候補で総当たりしない）")
    func stemNarrowsTheSearch() {
        // メンバー 20,000 枚（元の名前が分かる）・外した写真 300 枚。総当たりなら 1,200 万回で上限を越える。
        let members = (0..<20_000).map { "L-m\($0)" }
        var names: [String: String] = [:]
        for (index, key) in members.enumerated() { names[key] = "IMG_\(index).jpg" }
        let removed = (0..<300).map { file(path("L-gone\($0)", hash: "g\($0)", name: "IMG_\($0).jpg"), "g\($0)") }
        let kept = file(path("L-m7", hash: "old", name: "IMG_7.jpg"), "old")
        let verdicts = ShareDeletionReview.classify(
            candidates: removed + [kept], members: members, sourceFileNames: names,
            destinationByRefKey: [:], presentAfterCopy: [], presentHashes: [], startOffset: 0)
        #expect(!verdicts.values.contains(.deferred), "幹で絞らずに上限を使い切った")
        #expect(verdicts[kept.pathLower] == .keptForMember(refKey: "L-m7"))
        #expect(removed.allSatisfy { verdicts[$0.pathLower] == .needsEvidence(ownerRefKey: nil) })
    }

    @Test("元の名前が分からないメンバー（記録が消えた）は総当たりで引き当てる")
    func unnamedMembersAreSearched() {
        let copy = path("L-lost", hash: "hl", name: "anything.jpg")
        let verdicts = ShareDeletionReview.classify(
            candidates: [file(copy, "hl")], members: ["L-lost", "L-other"],
            sourceFileNames: ["L-other": "anything.jpg"],
            destinationByRefKey: [:], presentAfterCopy: [], presentHashes: [], startOffset: 0)
        #expect(verdicts[copy] == .keptForMember(refKey: "L-lost"))
    }

    @Test("印の 16 進は以前の作り方と同じ（置き済みのファイル名が変わらない）")
    func identityHexIsUnchanged() {
        // ⚠️ 16 進化を速くしたので、以前の `String(format: "%02x")` と 1 文字でも違うと、
        // 置き済みの全ファイルが「望ましくない名前」に見えて作り直しになる。
        for (refKey, hash) in [("L-p0", "h0"), ("C-/Camera Uploads/写真.jpg", nil), ("L-", "")] as [(String, String?)] {
            let seed = "\(refKey)|\(hash ?? "")"
            let legacy = SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(ShareNaming.identity(refKey: refKey, contentHash: hash) == legacy)
        }
    }

    @Test("上げ直しで名前が変わったメンバー（-edited・(1)）の古い版も、持ち主が分かる")
    func renamedSourceStillFindsOwner() {
        let old = path("L-p1", hash: "h1", name: "IMG_7.HEIC")
        let renamed = path("L-p2", hash: "h2", name: "IMG_8.jpg")
        let verdicts = ShareDeletionReview.classify(
            candidates: [file(old, "h1"), file(renamed, "h2")], members: ["L-p1", "L-p2"],
            sourceFileNames: ["L-p1": "IMG_7-edited.jpg", "L-p2": "IMG_8 (1).jpg"],
            destinationByRefKey: [:], presentAfterCopy: [], presentHashes: [], startOffset: 0)
        #expect(verdicts[old] == .keptForMember(refKey: "L-p1"))
        #expect(verdicts[renamed] == .keptForMember(refKey: "L-p2"))
    }

    @Test("持ち越しは回ごとに別の候補から始める（先頭の候補が毎回上限を食わない）")
    func rotationReachesLaterCandidates() {
        let members = (0..<10).map { "L-m\($0)" }
        let candidates = (0..<3).map { file(path("L-gone\($0)", hash: "g\($0)"), "g\($0)") }
        let sorted = candidates.map(\.pathLower).sorted()
        let second = ShareDeletionReview.classify(
            candidates: candidates, members: members, sourceFileNames: [:], destinationByRefKey: [:],
            presentAfterCopy: [], presentHashes: [], startOffset: 1, hashBudget: 20)
        #expect(second[sorted[1]] == .needsEvidence(ownerRefKey: nil))
        #expect(second[sorted[0]] == .deferred)
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
            layoutRoot: "/root",
            excludingPrefixes: ["/root/dev/share", "/root/dev/ShareRemoved"])
        #expect(locations["h0"] == ["/camera uploads/p0.jpg", "/root/dev/backup/2020/p0.jpg"])

        // 他の端末の共有コピーは、**印の無い名前**（旧方式・`(1)` 付き）でも証拠にしない。
        let others = ShareDeletionReview.locations(
            for: ["h0"], records: [],
            cloud: ["/root/other/share/trip/IMG_0001.jpg": "h0",
                    "/root/other/shareremoved/trip/x--abcd1234 (1).jpg": "h0",
                    "/mosaicshare/trip/IMG_0001.jpg": "h0",
                    "/root/other/backup/2020/IMG_0001.jpg": "h0"],
            layoutRoot: "/Root", excludingPrefixes: ["/MosaicShare"])
        #expect(others["h0"] == ["/root/other/backup/2020/img_0001.jpg"])
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
