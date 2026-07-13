import Foundation

/// 解釈（検索文 → QuerySpec・英訳）のライフサイクル。LLM 解釈＋翻訳＋防御的サニタイズ＋
/// 決定的レキシコンによる接地をここに集約し、結果を `AIAlbumInterpretationStore` へ永続化する。
///
/// 設計方針（根本見直し・2026-07）: **解釈は検索文の性質であり、ライブラリの性質ではない。**
/// LLM（解釈・翻訳）は**作成/編集時に 1 回だけ**実行して保存し、起動時・写真追加時には走らない
/// （旧: カタログ署名変化で全キャッシュ破棄→毎起動 LLM×全アルバム＝実測 9.4s のメインハング）。
/// 解釈に存在しない地名・人名が含まれてもよい。照合（QueryEvaluator）は部分一致なので、
/// 該当写真が索引され次第、自動的に当たり始める（再解釈は不要）。
@MainActor
public final class AIAlbumInterpreter {
    private let store: AutoAlbumStore
    private let understanding: QueryUnderstanding
    private let translator: QueryTranslator?
    private let interpretations = AIAlbumInterpretationStore()

    /// 名前付き人物（顔クラスタ）のフルネーム一覧を供給する seam。人物名検索の接地に使う
    /// （Composition Root が PeopleEngine を結線する）。未設定なら人物名接地は行わない。
    var namedPeopleProvider: (@Sendable () async -> [String])?

    init(store: AutoAlbumStore, understanding: QueryUnderstanding, translator: QueryTranslator?) {
        self.store = store
        self.understanding = understanding
        self.translator = translator
    }

    /// 現在の名前付き人物一覧（プロバイダ未設定なら空）。
    private func currentNamedPeople() async -> [String] {
        await namedPeopleProvider?() ?? []
    }

    // MARK: - 保存済み解釈への窓口（永続化はすべてここを経由する）

    func saved(for id: String) -> SavedInterpretation? { interpretations.get(id) }
    func save(_ value: SavedInterpretation, for id: String) { interpretations.set(id, value) }
    func remove(id: String) { interpretations.remove(id) }
    func removeAll() { interpretations.removeAll() }
    /// 再解析（全埋め込み作り直し）用：解釈は保持し、評価状態（プール・評価済み枚数）だけリセットする。
    func resetEvaluationStates() { interpretations.resetEvaluationStates() }
    /// ドリフト検知用: 保存済み解釈のうち最小の evaluatedEmbedCount（未保存アルバムは 0 扱い）。
    func minEvaluatedEmbedCount(for ids: [String]) -> Int {
        interpretations.minEvaluatedEmbedCount(for: ids)
    }

    /// Refine（空振り時の再検索）用のプローブ語生成（LLM）。
    func expandProbes(_ criteria: String) async -> [String] {
        await understanding.expandProbes(criteria)
    }

    // MARK: - 解釈（作成/編集時に 1 回だけ・永続化）

    /// 保存済み解釈を返す。無い・検索文が変わったときだけ LLM で解釈＋翻訳して保存する。
    /// カタログ（地名/人物の語彙）は LLM の表記寄せヒントとして**このときだけ**構築する。
    func interpretation(id: String, criteria: String, now: Date) async -> SavedInterpretation {
        // 検索文が同じでも、解釈器の版が古ければ作り直す（プロンプト改善を既存アルバムに波及させる）。
        if var saved = interpretations.get(id), saved.criteria == criteria,
           saved.version == SavedInterpretation.currentVersion,
           saved.pendingFinalization != true {   // プレビュー解釈は本番化の対象（キャッシュ扱いしない）
            // 翻訳が保留（前回失敗）なら翻訳だけ再試行する（解釈はそのまま）。
            if saved.translationPending == true, let translator {
                let english = await translator.toEnglish(criteria)
                if !Self.looksUntranslated(english) {
                    saved.semanticText = english
                    saved.translationPending = false
                    interpretations.set(id, saved)
                }
            }
            return saved
        }
        let all = await store.allEnrichedPhotosLite()
        let catalog = await Self.buildCatalogOffMain(all)
        // LLM 出力は必ずサニタイズする（プレースホルダ語・カタログ丸写し・include/exclude 衝突）。
        // P0: さらに接地する＝日付は決定的パーサに置換・place/people はカタログ/原文出現のみ
        // （小型オンデバイス LLM の構造化出力は信用しない＝実障害3件・sanitizer 参照）。
        var spec = QuerySpecSanitizer.sanitize(
            await understanding.interpretSpec(criteria, catalog: catalog, now: now),
            criteria: criteria, now: now,
            placeCatalog: catalog.places + catalog.countries,
            peopleCatalog: catalog.people)
        // 人物名の接地（決定的）: クエリが名前付き人物（フルネーム）を指すなら people 条件を足す。
        // 姓名の部分指定（太郎→木村太郎）・複数人物（太郎と花子）に対応。LLM が拾えた分と統合される。
        let named = await currentNamedPeople()
        let grounded = PersonNameGrounder.groundedNames(in: criteria, names: named)
        if !grounded.isEmpty { spec = QuerySpecSanitizer.addingPeople(spec, names: grounded) }
        // 決定的レキシコン（RelativeDateParser と同じ思想）: LLM が空振り/全滅しても、
        // 頻出の視覚語（風景→landscape 等）と人物否定（人が写っていない→exclude people）は
        // 原文から必ず立てる。LLM が動くときは LLM の内容語が優先（空のときだけ補う）。
        // 視覚語抽出は人名部分を除いた残りで行う（「花子」の「花」を flower と誤抽出しない）。
        let visualText = PersonNameGrounder.strippingNames(from: criteria, matched: grounded)
        if spec.allContentTerms.include.isEmpty {
            let lex = JapaneseVisualLexicon.includeTerms(in: visualText)
            if !lex.isEmpty { spec = QuerySpecSanitizer.withIncludeTerms(spec, terms: lex) }
        }
        if JapaneseVisualLexicon.hasPeopleNegation(criteria) {
            spec = QuerySpecSanitizer.addingExclusion(spec, terms: ["people"])
        }
        // P0: 翻訳失敗（日本語のまま等）は semanticText を空にして保存し、次回に再試行する。
        // 失敗を静かにキャッシュすると CLIP に非英語が渡り採点が全ノイズ化する（実障害2件）。
        let english = (await translator?.toEnglish(criteria)) ?? criteria
        let failed = Self.looksUntranslated(english)
        var saved = SavedInterpretation(criteria: criteria, spec: spec,
                                        semanticText: failed ? "" : english)
        saved.translationPending = failed
        saved.pendingFinalization = false   // full 解釈済み
        // マルチプローブ（ADR-35）: FM に言い換え（同義語・上位/下位概念）を生成させて永続化する。
        // 単語リスト生成は小型 LLM が壊れにくい形（expandProbes は空振り Refine と同じ実装）。
        // 採点は主フレーズ＋プローブの max-over-probes＝言い換えの取りこぼしを回収する。
        // 非 ASCII（英語でない）は CLIP に渡せないため落とす。ここも解釈時 1 回だけ（ADR-23）。
        let rawProbes = await understanding.expandProbes(criteria)
        saved.probes = Array(rawProbes.filter { $0.allSatisfy(\.isASCII) }.prefix(4))
        interpretations.set(id, saved)
        return saved
    }

    /// 即時プレビュー用の解釈（純・LLM なし・テスト対象）。決定的レイヤーだけで仮の spec を作る：
    /// 日付=RelativeDateParser・視覚語/人物否定=JapaneseVisualLexicon。semanticText は空
    /// （FM 翻訳は夜間）。pendingFinalization/translationPending を立てて返す。
    /// public: 検索品質ハーネス（SearchQualityTests）が本番と同じ決定的解釈を使うため。
    public nonisolated static func previewInterpretation(criteria: String, now: Date,
                                                         namedPeople: [String] = []) -> SavedInterpretation {
        var spec = QuerySpec()
        // 人物名の接地（決定的）を最優先で立てる。名前付き人物を指すクエリは、視覚語推定より
        // 人物条件を優先したい（「太郎」は被写体語ではなく人物）。
        let grounded = PersonNameGrounder.groundedNames(in: criteria, names: namedPeople)
        // 視覚語抽出は人名部分を除いた残りで行う（「花子」の「花」を flower と誤抽出しない）。
        let visualText = PersonNameGrounder.strippingNames(from: criteria, matched: grounded)
        let includes = JapaneseVisualLexicon.includeTerms(in: visualText)
        // 英語入力なら原文の語をそのまま include に使える（ASCII のみのとき）。
        // ただし人物名に接地できたときは、原文丸ごとの content 化はしない（人物条件を主にする）。
        if grounded.isEmpty && includes.isEmpty && criteria.allSatisfy(\.isASCII) {
            spec = QuerySpecSanitizer.withIncludeTerms(spec, terms: [criteria.lowercased()])
        } else if !includes.isEmpty {
            spec = QuerySpecSanitizer.withIncludeTerms(spec, terms: includes)
        }
        if !grounded.isEmpty {
            spec = QuerySpecSanitizer.addingPeople(spec, names: grounded)
        }
        if JapaneseVisualLexicon.hasPeopleNegation(criteria) {
            spec = QuerySpecSanitizer.addingExclusion(spec, terms: ["people"])
        }
        if let date = RelativeDateParser.parse(criteria, now: now) {
            if spec.clauses.isEmpty {
                spec.clauses = [QueryClause([.date(date)])]
            } else {
                spec.clauses = spec.clauses.map { QueryClause($0.conditions + [.date(date)]) }
            }
        }
        var saved = SavedInterpretation(criteria: criteria, spec: spec, semanticText: "")
        saved.translationPending = true
        saved.pendingFinalization = true
        return saved
    }

    /// 英訳として成立していないか（非 ASCII が 1/3 以上＝日本語のまま等）。純関数（テスト対象）。
    nonisolated static func looksUntranslated(_ english: String) -> Bool {
        let text = english.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        let nonAscii = text.unicodeScalars.filter { !$0.isASCII }.count
        return nonAscii * 3 > text.unicodeScalars.count
    }

    /// カタログ構築（85k 件の地名/人物集計）もオフメインで行う。
    nonisolated private static func buildCatalogOffMain(_ all: [EnrichedPhoto]) async -> AIAlbumCatalog {
        await Task.detached(priority: .utility) { AIAlbumCatalog.build(from: all) }.value
    }
}
