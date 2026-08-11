import Foundation
import Testing
@testable import AutoAlbumCore

/// 属性条件（S10・ADR-103）: 「笑っている」「綺麗な」を索引済みシグナルへのハード条件として評価する。
@Suite("Attribute conditions (.smiling / .beautiful)")
struct AttributeConditionTests {

    private func photo(_ id: String) -> EnrichedPhoto {
        EnrichedPhoto(id: id, captureDate: nil, latitude: nil, longitude: nil, placeName: nil)
    }
    private let now = Date(timeIntervalSince1970: 1_767_225_600)

    @Test("笑顔: 実測>0 は通す・0 は落とす・未スキャンは通さない（証拠主義）")
    func smilingRequiresEvidence() {
        let spec = QuerySpec(clauses: [QueryClause([.smiling])])
        let photos = [photo("smile"), photo("noSmile"), photo("unscanned")]
        let signals = QuerySignals(smileCounts: ["smile": 2, "noSmile": 0])
        let out = QueryEvaluator.hardFilter(photos, spec: spec, now: now, signals: signals)
        #expect(out.map(\.id) == ["smile"],
                "未スキャンを『笑っていない』でなく『不明』として落とすべき: \(out.map(\.id))")
    }

    @Test("綺麗: 分布適応しきい値以上を通す・未計測は通さない")
    func beautifulUsesAdaptiveFloor() {
        let spec = QuerySpec(clauses: [QueryClause([.beautiful])])
        let photos = [photo("high"), photo("low"), photo("unmeasured")]
        let signals = QuerySignals(aesthetics: ["high": 0.7, "low": 0.1], aestheticFloor: 0.5)
        let out = QueryEvaluator.hardFilter(photos, spec: spec, now: now, signals: signals)
        #expect(out.map(\.id) == ["high"])
    }

    @Test("シグナル未提供なら属性条件は全滅させる（誤って全件通さない）")
    func missingSignalsFailClosed() {
        let spec = QuerySpec(clauses: [QueryClause([.smiling])])
        let out = QueryEvaluator.hardFilter([photo("a")], spec: spec, now: now)
        #expect(out.isEmpty, "シグナル無しで笑顔条件が素通りしている")
    }

    @Test("レキシコン: 笑顔・綺麗の属性語を検出し、プレビュー解釈が条件を立てる")
    func lexiconDetectsAttributes() {
        #expect(JapaneseVisualLexicon.hasSmileRequest("笑っている子供の写真"))
        #expect(JapaneseVisualLexicon.hasBeautifulRequest("綺麗な風景"))
        #expect(!JapaneseVisualLexicon.hasSmileRequest("子供の写真"))

        let smile = AIAlbumInterpreter.previewInterpretation(criteria: "笑っている写真", now: now)
        #expect(smile.spec.needsSmileSignal)
        let beautiful = AIAlbumInterpreter.previewInterpretation(criteria: "2024年の綺麗な写真", now: now)
        #expect(beautiful.spec.needsAestheticSignal)
        #expect(beautiful.spec.clauses.allSatisfy { $0.conditions.contains(.date(.year(2024))) })
        // 複合: 属性＋内容語が同居する。
        let composite = AIAlbumInterpreter.previewInterpretation(criteria: "笑っている子供の写真", now: now)
        #expect(composite.spec.needsSmileSignal)
        #expect(composite.spec.allContentTerms.include == ["child", "children"])
    }
}
