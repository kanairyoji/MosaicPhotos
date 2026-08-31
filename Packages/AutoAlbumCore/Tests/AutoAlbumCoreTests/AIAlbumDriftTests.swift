import Foundation
import Testing
@testable import AutoAlbumCore

/// フル再評価の要否は**アルバム単位**で決める（ADR-160）。
///
/// ⚠️ 以前は「保存済みの最小 evaluatedEmbedCount」だけを見ていたため、1 本でも遅れていると
/// 追いついている本まで作り直していた。1 本の再評価は台帳の埋め込み（実機 85,090 件）を
/// 1 周流すので、5 本なら 5 周——実機のディスク書き込み警告（33 分で 1.07GB）の主因。
@Suite("AI アルバムのドリフト判定")
struct AIAlbumDriftTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func spec(lastDays: Int? = nil) -> QuerySpec {
        guard let lastDays else { return QuerySpec(clauses: [QueryClause([.content(["sea"])])]) }
        return QuerySpec(clauses: [QueryClause([.date(.lastDays(lastDays)), .content(["sea"])])])
    }

    @Test("追いついている本は再評価しない")
    func upToDateAlbumIsSkipped() {
        let needs = AIAlbumDrift.needsFullEvaluation(
            version: SavedInterpretation.currentVersion, spec: spec(),
            lastEvaluatedAt: now, evaluatedEmbedCount: 85_000,
            embedCount: 85_090, threshold: 500, now: now)
        #expect(needs == false, "差が閾値以下なら流し直さない")
    }

    @Test("埋め込みが閾値を超えて進んだ本だけ再評価する")
    func driftedAlbumIsEvaluated() {
        let needs = AIAlbumDrift.needsFullEvaluation(
            version: SavedInterpretation.currentVersion, spec: spec(),
            lastEvaluatedAt: now, evaluatedEmbedCount: 84_000,
            embedCount: 85_090, threshold: 500, now: now)
        #expect(needs, "1,090 件も未評価なら作り直す")
    }

    @Test("解釈器の版が古い本は、埋め込みの進行に関係なく再評価する")
    func staleVersionIsEvaluated() {
        let needs = AIAlbumDrift.needsFullEvaluation(
            version: SavedInterpretation.currentVersion - 1, spec: spec(),
            lastEvaluatedAt: now, evaluatedEmbedCount: 85_090,
            embedCount: 85_090, threshold: 500, now: now)
        #expect(needs, "評価規則が変わった本は作り直す")
    }

    @Test("「直近◯日」は日をまたいだら再評価する")
    func timeDependentAlbumIsEvaluatedNextDay() {
        let yesterday = now.addingTimeInterval(-24 * 3600)
        let needs = AIAlbumDrift.needsFullEvaluation(
            version: SavedInterpretation.currentVersion, spec: spec(lastDays: 30),
            lastEvaluatedAt: yesterday, evaluatedEmbedCount: 85_090,
            embedCount: 85_090, threshold: 500, now: now)
        #expect(needs, "期間が動くアルバムは日付が変わったら作り直す")

        let sameDay = AIAlbumDrift.needsFullEvaluation(
            version: SavedInterpretation.currentVersion, spec: spec(lastDays: 30),
            lastEvaluatedAt: now, evaluatedEmbedCount: 85_090,
            embedCount: 85_090, threshold: 500, now: now)
        #expect(sameDay == false, "同じ日に何度も流し直さない")
    }
}
