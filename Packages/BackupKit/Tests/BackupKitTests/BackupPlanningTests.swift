import Foundation
import Testing
@testable import BackupKit

/// 何を上げるか（ADR-275）。旧 `BackupPlanning.pendingUploads` の性質（済みを除く・順序・上限）を
/// 引き継ぎ、対象の違い（全部／共有する写真だけ）と共有の優先を足した。
@Suite("BackupScopePolicy.uploadTargets")
struct UploadTargetsTests {

    private func targets(_ library: [String], uploaded: Set<String> = [],
                         awaited: Set<String> = [], scope: BackupScope = .everything,
                         limit: Int = 0) -> (pending: [String], skipped: Int, prioritized: Int) {
        BackupScopePolicy.uploadTargets(library: library, alreadyUploaded: uploaded,
                                        awaitedByShare: awaited, scope: scope, limit: limit)
    }

    @Test("アップロード済みを除外し未アップロードのみ返す")
    func excludesUploaded() {
        let result = targets(["a", "b", "c"], uploaded: ["b"])
        #expect(result.pending == ["a", "c"])
        #expect(result.skipped == 1)
    }

    @Test("表示順を保持する")
    func preservesOrder() {
        #expect(targets(["x", "y", "z", "w"]).pending == ["x", "y", "z", "w"])
    }

    @Test("limit>0 で上限を適用する（スキップ数は上限の影響を受けない）")
    func appliesLimit() {
        let result = targets(["a", "b", "c", "d", "e"], uploaded: ["a"], limit: 2)
        #expect(result.pending == ["b", "c"])
        #expect(result.skipped == 1)
    }

    @Test("limit<=0 は無制限")
    func zeroLimitMeansUnlimited() {
        #expect(targets((0..<100).map { "id\($0)" }).pending.count == 100)
    }

    @Test("全件アップロード済みなら pending は空")
    func allUploaded() {
        let result = targets(["a", "b"], uploaded: ["a", "b"])
        #expect(result.pending.isEmpty)
        #expect(result.skipped == 2)
    }

    // MARK: - 対象（ADR-275）

    @Test("共有する写真だけ: 共有で待たれている写真だけが対象")
    func sharedOnlyUploadsOnlyShareMembers() {
        let result = targets(["a", "b", "c", "d"], awaited: ["b", "d"], scope: .sharedOnly)
        #expect(result.pending == ["b", "d"])
        #expect(result.prioritized == 2)
    }

    @Test("共有する写真だけ: 共有メンバーが居なければ何も上げない")
    func sharedOnlyWithoutMembersUploadsNothing() {
        #expect(targets(["a", "b"], scope: .sharedOnly).pending.isEmpty)
    }

    @Test("共有する写真だけ: 上げ済みの共有メンバーは上げ直さない")
    func sharedOnlySkipsUploadedMembers() {
        let result = targets(["a", "b"], uploaded: ["a"], awaited: ["a", "b"], scope: .sharedOnly)
        #expect(result.pending == ["b"])
    }

    @Test("全部: 共有で待たれている写真が先頭（相対順は保つ）")
    func everythingPutsShareMembersFirst() {
        let result = targets(["a", "b", "c", "d"], awaited: ["d", "b"])
        #expect(result.pending == ["b", "d", "a", "c"])
    }

    /// ⚠️ 以前は上限を**先に**掛けてから共有メンバーを前へ出したので、上限の外に居る
    /// 共有メンバーは優先されず、何日も共有が進まなかった。
    @Test("共有で待たれている写真は上限に数えない（上限の外に居ても上げる）")
    func shareMembersAreNotCappedByTheLimit() {
        let library = (0..<50).map { "p\($0)" }
        let result = targets(library, awaited: ["p40", "p45"], limit: 3)
        #expect(result.pending == ["p40", "p45", "p0", "p1", "p2"])

        let sharedOnly = targets(library, awaited: ["p40", "p45"], scope: .sharedOnly, limit: 1)
        #expect(sharedOnly.pending == ["p40", "p45"], "共有する写真だけでも上限で切っている")
    }

    @Test("ライブラリに無い共有メンバー（写真が消えた）は対象にしない")
    func missingShareMembersAreIgnored() {
        #expect(targets(["a"], awaited: ["a", "gone"], scope: .sharedOnly).pending == ["a"])
    }
}

@Suite("BackupScopePolicy（やるか・やらないか）")
struct BackupScopePolicyGateTests {

    @Test("設定の読み替え: Dropbox＝全部、それ以外（未設定・旧「バックアップしない」）＝共有する写真だけ")
    func scopeFromSettings() {
        let defaults = TestDefaults.scratch("scope")
        #expect(BackupScope.current(defaults) == .sharedOnly, "未設定が全部になっている（勝手に全部上げる）")
        defaults.set(BackupDestination.disabled.rawValue, forKey: BackupSettingsKeys.destination)
        #expect(BackupScope.current(defaults) == .sharedOnly)
        defaults.set(BackupDestination.dropbox.rawValue, forKey: BackupSettingsKeys.destination)
        #expect(BackupScope.current(defaults) == .everything)
        defaults.set("garbage", forKey: BackupSettingsKeys.destination)
        #expect(BackupScope.current(defaults) == .sharedOnly, "壊れた値で全部を上げ始める")
    }

    @Test("走る意味: 全部なら常に、共有する写真だけなら待っている写真があるときだけ")
    func hasWork() {
        #expect(BackupScopePolicy.hasWork(scope: .everything, awaitedCount: 0))
        #expect(!BackupScopePolicy.hasWork(scope: .sharedOnly, awaitedCount: 0))
        #expect(BackupScopePolicy.hasWork(scope: .sharedOnly, awaitedCount: 1))
    }

    @Test("候補の列挙: 共有する写真だけなら共有メンバーに限る（全ライブラリを列挙しない）")
    func candidateRestriction() {
        #expect(BackupScopePolicy.candidateRestriction(scope: .everything, awaitedByShare: ["a"]) == nil)
        #expect(BackupScopePolicy.candidateRestriction(scope: .sharedOnly, awaitedByShare: ["a"]) == ["a"])
    }

    @Test("オフロードは全部のときだけ（共有しただけの写真を端末から消さない）")
    func offload() {
        #expect(BackupScopePolicy.allowsOffload(scope: .everything))
        #expect(!BackupScopePolicy.allowsOffload(scope: .sharedOnly))
    }

    @Test("照合: 共有する写真だけでも、上げたものがあれば走る／無ければ一覧を引かない")
    func reconcile() {
        var asked = 0
        #expect(BackupScopePolicy.allowsReconcile(scope: .everything, hasUploads: { asked += 1; return false }))
        #expect(asked == 0, "全部のときに記録を読みに行っている（数万件の台帳を無駄に読む）")
        #expect(BackupScopePolicy.allowsReconcile(scope: .sharedOnly, hasUploads: { true }))
        #expect(!BackupScopePolicy.allowsReconcile(scope: .sharedOnly, hasUploads: { false }))
    }
}

@Suite("BackupPlanning.dropboxErrorSummary")
struct DropboxErrorSummaryTests {

    @Test("error_summary フィールドを抽出する")
    func extractsErrorSummary() {
        let body = #"{"error_summary": "path/not_found/...", "error": {}}"#
        #expect(BackupPlanning.dropboxErrorSummary(from: body) == "path/not_found/...")
    }

    @Test("JSON でなければ本文の先頭を返す")
    func fallsBackToBody() {
        let body = "Internal Server Error"
        #expect(BackupPlanning.dropboxErrorSummary(from: body) == "Internal Server Error")
    }

    @Test("error_summary が無い JSON は本文先頭を返す")
    func missingFieldFallsBack() {
        let body = #"{"other": "value"}"#
        #expect(BackupPlanning.dropboxErrorSummary(from: body) == body)
    }

    @Test("長い本文は先頭300文字に切り詰める")
    func truncatesLongBody() {
        let body = String(repeating: "x", count: 500)
        #expect(BackupPlanning.dropboxErrorSummary(from: body).count == 300)
    }
}
