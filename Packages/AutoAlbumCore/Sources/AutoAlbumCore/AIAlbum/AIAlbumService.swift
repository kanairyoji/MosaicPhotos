import Foundation
import MosaicSupport

/// AI アルバムの作成・再設定・削除・再評価をまとめた協調オブジェクト。
/// 状態（公開アルバム配列）はエンジンが持ち、本サービスは store を更新して最新の AI アルバム一覧を返す。
///
/// 設計方針（根本見直し・2026-07）: **解釈は検索文の性質であり、ライブラリの性質ではない。**
/// - LLM（解釈・翻訳）は**作成/編集時に 1 回だけ**実行し、`AIAlbumInterpretationStore` に永続化する。
///   起動時・写真追加時に LLM は一切走らない（旧: カタログ署名変化で全キャッシュ破棄→毎起動 LLM×全アルバム
///   ＝実測 9.4s のメインハング）。
/// - 解釈に存在しない地名・人名が含まれてもよい。照合（QueryEvaluator）は部分一致なので、
///   該当写真が索引され次第、自動的に当たり始める（再解釈は不要）。
/// - 再評価はフル（全ベクトルをページ走査）と**増分**（新規埋め込み分だけ採点してプールへマージ）の
///   2 経路。日常は増分、ズレが開いたらアイドル時にフルで整合を回復する。
@MainActor
final class AIAlbumService {
    private let store: AutoAlbumStore
    private let understanding: QueryUnderstanding
    private let searcher: AIAlbumSearcher
    private let translator: QueryTranslator?
    private let interpretations = AIAlbumInterpretationStore()
    /// 英訳フレーズ＋除外語 → CLIP テキスト埋め込み（肯定＋除外群）のメモリキャッシュ
    /// （増分評価で毎回エンコードしない）。
    private var queryVectorCache: [String: (pos: [Float], negs: [[Float]])] = [:]
    private let textEmbedder: TextEmbedder?
    /// 顔スキャンの実測（refKey → 顔数）を返す seam。FaceStore は別コンテナ（PeopleEngine 側）の
    /// ため init 連鎖でなく Composition Root から `AutoAlbumEngine.setFaceCountsProvider` で結線する。
    /// 「人」系の除外があるアルバムの評価で、顔が実際に写っている写真をハード除外するのに使う。
    var faceCountsProvider: (@Sendable () async -> [String: Int])?

    init(store: AutoAlbumStore, understanding: QueryUnderstanding, textEmbedder: TextEmbedder?,
         translator: QueryTranslator? = nil) {
        self.store = store
        self.understanding = understanding
        self.translator = translator
        self.textEmbedder = textEmbedder
        self.searcher = AIAlbumSearcher(textEmbedder: textEmbedder)
    }

    // MARK: - 解釈（作成/編集時に 1 回だけ・永続化）

    /// 保存済み解釈を返す。無い・検索文が変わったときだけ LLM で解釈＋翻訳して保存する。
    /// カタログ（地名/人物の語彙）は LLM の表記寄せヒントとして**このときだけ**構築する。
    private func interpretation(id: String, criteria: String, now: Date) async -> SavedInterpretation {
        // 検索文が同じでも、解釈器の版が古ければ作り直す（プロンプト改善を既存アルバムに波及させる）。
        if let saved = interpretations.get(id), saved.criteria == criteria,
           saved.version == SavedInterpretation.currentVersion { return saved }
        let all = await store.allEnrichedPhotosLite()
        let catalog = await Self.buildCatalogOffMain(all)
        let spec = await understanding.interpretSpec(criteria, catalog: catalog, now: now)
        let english = (await translator?.toEnglish(criteria)) ?? criteria
        let saved = SavedInterpretation(criteria: criteria, spec: spec, semanticText: english)
        interpretations.set(id, saved)
        return saved
    }

    // MARK: - 作成 / 再設定 / 削除

    /// 作成/再設定（共通）。**0 件でも保存**する。戻り値: (結果, 更新後の AI アルバム一覧 or nil)。
    func make(id: String, title: String, criteria: String) async -> (result: AIAlbumResult, albums: [AutoAlbumInfo]?) {
        let trimmed = criteria.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (.empty, nil) }

        let now = Date()
        interpretations.remove(id)   // 再設定（検索文変更）は解釈からやり直す
        var saved = await interpretation(id: id, criteria: trimmed, now: now)
        let all = await store.allEnrichedPhotosLite()
        let (members, pool) = await rankedSearch(all, saved: saved, now: now)
        saved.scoredPool = pool
        saved.evaluatedEmbedCount = await store.embeddedCount()
        interpretations.set(id, saved)
        Diagnostics.mark("aialbum.make: '\(trimmed)' all=\(all.count) members=\(members.count)")
        let info = AIAlbumSearcher.buildInfo(id: id, title: title, interpretedTitle: saved.spec.title,
                                             criteria: trimmed, members: members)
        await store.upsert(albumInfo: info)
        return (.created(info), await loadAll())
    }

    func delete(id: String) async -> [AutoAlbumInfo] {
        await store.deleteAlbum(id: id)
        interpretations.remove(id)
        return await loadAll()
    }

    // MARK: - 再評価（LLM なし）

    /// フル再評価：保存済み解釈で全写真を採点し直す（プール・評価済み枚数も更新）。
    /// LLM は走らない（解釈未保存のアルバムだけ初回に 1 回解釈して保存＝旧データの移行）。
    func refresh(_ current: [AutoAlbumInfo]) async -> [AutoAlbumInfo] {
        Diagnostics.mark("aialbum.refresh: aiAlbums=\(current.count)")
        guard !current.isEmpty else { return current }
        let now = Date()
        let all = await store.allEnrichedPhotosLite()
        let embedCount = await store.embeddedCount()

        var updated: [AutoAlbumInfo] = []
        for album in current {
            guard let criteria = album.criteria, !criteria.isEmpty else { updated.append(album); continue }
            var saved = await interpretation(id: album.id, criteria: criteria, now: now)
            let (members, pool) = await rankedSearch(all, saved: saved, now: now)
            saved.scoredPool = pool
            saved.evaluatedEmbedCount = embedCount
            interpretations.set(album.id, saved)
            let info = AIAlbumSearcher.buildInfo(id: album.id, title: album.title, interpretedTitle: saved.spec.title,
                                                 criteria: criteria, members: members)
            await store.upsert(albumInfo: info)
            updated.append(info)
        }
        return updated.sorted { $0.representativeDate > $1.representativeDate }
    }

    /// 増分再評価（Phase 2）：**新規に埋め込まれた refKey 群だけ**を採点してプールへマージし、
    /// 閾値を超えた写真をメンバーへ追加する。全ベクトルのページ走査・LLM は一切行わない。
    /// 解釈やプールが未保存のアルバムは触らない（ドリフト検知のフル再評価に任せる）。
    func refreshIncremental(newRefKeys: [String], current: [AutoAlbumInfo]) async -> [AutoAlbumInfo] {
        guard !current.isEmpty, !newRefKeys.isEmpty else { return current }
        let now = Date()
        let newPhotos = await store.enrichedPhotos(forRefKeys: newRefKeys)
        let newVectors = await store.vectors(forRefKeys: newRefKeys)
        guard !newPhotos.isEmpty else { return current }

        var updated = current
        var touched = 0
        for (index, album) in current.enumerated() {
            guard let criteria = album.criteria, !criteria.isEmpty,
                  var saved = interpretations.get(album.id), saved.criteria == criteria,
                  saved.evaluatedEmbedCount > 0 else { continue }

            // ハード条件（相対日付は now で解決）を新規分に適用。
            var base = QueryEvaluator.hardFilter(newPhotos, spec: saved.spec, now: now)
            saved.evaluatedEmbedCount += newRefKeys.count
            // 対策2: 人系の除外があれば顔の実測（faceCount>0）をハード除外（フル評価と同じ規則）。
            if let faceCounts = await faceCountsIfNeeded(for: saved.spec) {
                base = base.filter { (faceCounts[$0.id] ?? 0) == 0 }
            }
            guard !base.isEmpty else { interpretations.set(album.id, saved); continue }

            // 意味採点（クエリ埋め込みはキャッシュ）。埋め込み不可なら評価枚数だけ進める。
            guard let q = await queryVectors(for: saved) else {
                interpretations.set(album.id, saved)
                continue
            }
            var added: [String: Float] = [:]
            for photo in base {
                guard let data = newVectors[photo.id], let v = ClipMath.decode(data) else { continue }
                let pos = ClipMath.cosine(q.pos, v)
                // 対策1: 除外概念との対比（フル評価と同じドロップ規則）。
                if !q.negs.isEmpty {
                    let neg = q.negs.map { ClipMath.cosine($0, v) }.max() ?? -1
                    if neg >= pos || neg >= AIAlbumSearcher.excludeDropThreshold { continue }
                }
                added[photo.id] = pos
            }
            guard !added.isEmpty else { interpretations.set(album.id, saved); continue }

            saved.scoredPool = AIAlbumSearcher.mergePool(saved.scoredPool, adding: added)
            interpretations.set(album.id, saved)

            // 閾値を超えた新規だけメンバーへ追加（既存メンバーは維持・並びは日付降順で再構成）。
            let memberKeys = Set(AIAlbumSearcher.memberKeys(fromPool: saved.scoredPool))
            let existing = Set(album.memberRefs)
            let newlyIn = base.filter { memberKeys.contains($0.id) && !existing.contains($0.id) }
            guard !newlyIn.isEmpty else { continue }

            let existingPhotos = await store.enrichedPhotos(forRefKeys: album.memberRefs)
            let members = (existingPhotos + newlyIn)
                .sorted { ($0.captureDate ?? .distantPast) > ($1.captureDate ?? .distantPast) }
            let info = AIAlbumSearcher.buildInfo(id: album.id, title: album.title, interpretedTitle: saved.spec.title,
                                                 criteria: criteria, members: members)
            await store.upsert(albumInfo: info)
            updated[index] = info
            touched += 1
        }
        if touched > 0 {
            Diagnostics.mark("aialbum.incremental: new=\(newRefKeys.count) touched=\(touched)/\(current.count)")
        }
        return updated.sorted { $0.representativeDate > $1.representativeDate }
    }

    /// ドリフト検知：保存済みの評価時点と現在の埋め込み枚数の差が `threshold` を超えていたら
    /// フル再評価する（アイドル時のティックから呼ぶ）。差が小さければ nil（何もしない）。
    /// 解釈未保存のアルバム（旧データ）は evaluated=0 扱いになるため、ここで初回移行も担う。
    func refreshIfDrifted(_ current: [AutoAlbumInfo], threshold: Int = 500) async -> [AutoAlbumInfo]? {
        guard !current.isEmpty else { return nil }
        let embedCount = await store.embeddedCount()
        let evaluated = interpretations.minEvaluatedEmbedCount(for: current.map(\.id))
        guard embedCount - evaluated > threshold else { return nil }
        Diagnostics.mark("aialbum.drift: embedded=\(embedCount) evaluated=\(evaluated) → full refresh")
        return await refresh(current)
    }

    func clearCache() {
        interpretations.removeAll()
        queryVectorCache = [:]
    }

    /// 再解析（全埋め込み作り直し）時：解釈は保持し、評価状態だけリセットする。
    func resetEvaluationState() {
        interpretations.resetEvaluationStates()
        queryVectorCache = [:]
    }

    // MARK: - Private

    /// 増分評価用のクエリ埋め込み（肯定＋除外群）。フル評価（searchWithPool）と同じ規則：
    /// 除外があるときの肯定側は include 語だけ（全文の否定は CLIP に効かないため）。
    private func queryVectors(for saved: SavedInterpretation) async -> (pos: [Float], negs: [[Float]])? {
        let include = saved.spec.allContentTerms.include
        let exclude = saved.spec.allContentTerms.exclude
        let phrase: String
        if !exclude.isEmpty && !include.isEmpty {
            phrase = include.joined(separator: ", ")
        } else {
            phrase = saved.semanticText.isEmpty ? include.joined(separator: ", ") : saved.semanticText
        }
        guard !phrase.isEmpty else { return nil }
        let cacheKey = "\(phrase)|\(exclude.joined(separator: ","))"
        if let cached = queryVectorCache[cacheKey] { return cached }
        guard let textEmbedder, textEmbedder.isAvailable,
              let pos = await textEmbedder.embed(phrase) else { return nil }
        var negs: [[Float]] = []
        for term in exclude {
            if let neg = await textEmbedder.embed(AIAlbumSearcher.excludePrompt(term)) { negs.append(neg) }
        }
        let result = (pos: pos, negs: negs)
        queryVectorCache[cacheKey] = result
        return result
    }

    /// 「人」系の除外があるアルバムなら顔の実測を取得する（無関係なアルバムでは取得しない）。
    private func faceCountsIfNeeded(for spec: QuerySpec) async -> [String: Int]? {
        guard AIAlbumSearcher.hasPeopleExclusion(spec), let faceCountsProvider else { return nil }
        return await faceCountsProvider()
    }

    private func rankedSearch(_ allLite: [EnrichedPhoto], saved: SavedInterpretation,
                              now: Date) async -> (members: [EnrichedPhoto], pool: [String: Float]) {
        // 意味検索の clipVector はストアからページ単位で読む（一度に全件を載せない）。
        // ⚠️ スコアリング（数万件×512 次元コサイン＋フィルタ）は CPU を食うので Task.detached で
        // オフメイン実行する（本サービスは @MainActor。直呼びだと ~1s 級のメイン占有になる）。
        let searcher = self.searcher
        let store = self.store
        let spec = saved.spec
        let semanticText = saved.semanticText
        let faceCounts = await faceCountsIfNeeded(for: spec)
        return await Task.detached(priority: .utility) {
            let (members, pool) = await searcher.searchWithPool(
                baseLite: allLite, spec: spec, now: now, semanticText: semanticText,
                faceCounts: faceCounts,
                loadPage: { offset, limit in
                    await store.enrichmentVectorPage(offset: offset, limit: limit)
                })
            let sorted = members.sorted { ($0.captureDate ?? .distantPast) > ($1.captureDate ?? .distantPast) }
            return (sorted, pool)
        }.value
    }

    /// カタログ構築（85k 件の地名/人物集計）もオフメインで行う。
    nonisolated private static func buildCatalogOffMain(_ all: [EnrichedPhoto]) async -> AIAlbumCatalog {
        await Task.detached(priority: .utility) { AIAlbumCatalog.build(from: all) }.value
    }

    private func loadAll() async -> [AutoAlbumInfo] {
        (await store.allAlbums())
            .filter { $0.strategyID == AIAlbumStrategy.strategyID }
            .sorted { $0.representativeDate > $1.representativeDate }
    }
}
