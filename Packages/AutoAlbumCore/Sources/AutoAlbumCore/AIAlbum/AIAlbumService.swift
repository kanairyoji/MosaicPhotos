import Foundation
import MosaicSupport

/// AI アルバムの作成・再設定・削除・再評価をまとめた**薄いファサード**。
/// 状態（公開アルバム配列）はエンジンが持ち、本サービスは store を更新して最新の AI アルバム一覧を返す。
/// 実処理は関心ごとの協調オブジェクトへ委譲する：
/// - 解釈（LLM 解釈＋翻訳＋サニタイズ＋永続化）: `AIAlbumInterpreter`
/// - 検索（タグ一致＋CLIP 対比＋字句の RRF 融合）: `AIAlbumSearcher`
/// - クエリ埋め込み（肯定フレーズ選定＋除外語ベクトル）: `QueryEmbedder`（フル/増分で同一実装）
/// - 証拠ゲート＋LLM 審査（self-consistency 多数決）: `AIAlbumVerificationCoordinator`
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
    private let searcher: AIAlbumSearcher
    /// 解釈のライフサイクル（LLM 解釈＋翻訳＋接地＋`AIAlbumInterpretationStore` への永続化）。
    private let interpreter: AIAlbumInterpreter
    /// P2: 証拠ゲート＋LLM 審査（FM 無し端末では審査スキップ）。
    private let verification: AIAlbumVerificationCoordinator
    /// クエリ埋め込み（フル評価と増分評価で**同じ規則**を型で担保する）。
    private let embedder: QueryEmbedder
    /// 英訳フレーズ＋除外語 → CLIP テキスト埋め込み（肯定＋除外群）のメモリキャッシュ
    /// （増分評価で毎回エンコードしない）。
    private var queryVectorCache: [String: QueryEmbedder.QueryVectors] = [:]
    /// 顔スキャンの実測（refKey → 顔数）を返す seam。FaceStore は別コンテナ（PeopleEngine 側）の
    /// ため init 連鎖でなく Composition Root から `AutoAlbumEngine.setFaceCountsProvider` で結線する。
    /// 「人」系の除外があるアルバムの評価で、顔が実際に写っている写真をハード除外するのに使う。
    var faceCountsProvider: (@Sendable () async -> [String: Int])? {
        get { verification.faceCountsProvider }
        set { verification.faceCountsProvider = newValue }
    }

    /// Phase 2（ADR-35）: 候補上位へのオンデマンドキャプション生成（審査の証拠を濃くする）。
    /// エンジンが TagPerceptionProvider＋TagStore で結線する。
    var captionOnDemand: (@Sendable ([String]) async -> [String: String])? {
        get { verification.captionOnDemand }
        set { verification.captionOnDemand = newValue }
    }

    /// 顔クラスタの**現在の**人物名（refKey → 名前）を返す seam。人物条件（.people 等）は
    /// `EnrichedPhoto.people`（初回焼き込み・更新されない）でなく **live 照合**する（実障害:
    /// 後から命名した人物が検索に反映されない）。Composition Root から結線。
    var peopleByRefKeyProvider: (@Sendable () async -> [String: [String]])?

    /// 人物条件があるアルバムだけ live 人物名マップを取得する（無関係なアルバムでは取得しない）。
    private func peopleMapIfNeeded(for spec: QuerySpec) async -> [String: [String]]? {
        guard spec.hasPeopleConditions, let peopleByRefKeyProvider else { return nil }
        return await peopleByRefKeyProvider()
    }

    /// 名前付き人物（顔クラスタ）のフルネーム一覧を返す seam（人物名検索の接地用）。
    /// 解釈器へ委譲。Composition Root が `AutoAlbumEngine.setNamedPeopleProvider` で結線する。
    var namedPeopleProvider: (@Sendable () async -> [String])? {
        get { interpreter.namedPeopleProvider }
        set { interpreter.namedPeopleProvider = newValue }
    }

    /// シーンタグ・キャプションのストア（検索の一次ランキングと LLM 審査の入力）。
    private let tagStore: TagStore?

    init(store: AutoAlbumStore, tagStore: TagStore? = nil,
         understanding: QueryUnderstanding, textEmbedder: TextEmbedder?,
         translator: QueryTranslator? = nil) {
        self.tagStore = tagStore
        self.store = store
        self.interpreter = AIAlbumInterpreter(store: store, understanding: understanding,
                                              translator: translator)
        self.verification = AIAlbumVerificationCoordinator(tagStore: tagStore)
        self.embedder = QueryEmbedder(textEmbedder: textEmbedder)
        self.searcher = AIAlbumSearcher(textEmbedder: textEmbedder)
    }

    // MARK: - 夜間の本番化（FM 解釈＋LLM 審査つきフル評価）

    /// 夜間の本番化: プレビューのまま（pendingFinalization）のアルバムだけ FM 解釈＋フル評価
    /// （証拠ゲート・LLM 審査・Refine 込み）を行う。ゲートが閉じたら残りは次回夜間へ。
    func finalizePending(_ albums: [AutoAlbumInfo], now: Date = Date()) async -> [AutoAlbumInfo] {
        let pendingIDs = albums.filter { interpreter.saved(for: $0.id)?.pendingFinalization == true }.map(\.id)
        guard !pendingIDs.isEmpty else { return albums }
        Diagnostics.mark("aialbum.finalize: \(pendingIDs.count) pending")
        var out = albums
        let all = await store.allEnrichedPhotosLite()
        let embedCount = await store.embeddedCount()
        for id in pendingIDs {
            if BackgroundYield.heavyShouldPause() { break }   // ロック解除等 → 残りは次回夜間へ
            guard let index = out.firstIndex(where: { $0.id == id }),
                  let criteria = out[index].criteria, !criteria.isEmpty else { continue }
            // interpretation() は pending の解釈をキャッシュ扱いしない＝ここで FM 解釈が走る。
            var saved = await interpreter.interpretation(id: id, criteria: criteria, now: now)
            var (members, pool) = await rankedSearch(all, saved: saved, now: now)
            members = await verification.evidenceGatedIfExcluding(members, spec: saved.spec)
            members = await verification.verified(members, criteria: criteria)
            // Refine: 空振りなら LLM がプローブ語を生成して 1 回だけ再検索（作成時から夜間へ移動）。
            if members.isEmpty {
                let probes = await interpreter.expandProbes(criteria)
                if !probes.isEmpty {
                    var alt = saved
                    alt.spec = QuerySpecSanitizer.withIncludeTerms(saved.spec, terms: probes)
                    let retry = await rankedSearch(all, saved: alt, now: now)
                    members = await verification.verified(retry.members, criteria: criteria)
                    if !members.isEmpty { pool = retry.pool }
                    Diagnostics.mark("aialbum.refine: probes=\(probes.joined(separator: ",")) → \(members.count)")
                }
            }
            saved.scoredPool = pool
            saved.evaluatedEmbedCount = embedCount
            interpreter.save(saved, for: id)
            let info = AIAlbumSearcher.buildInfo(id: id, title: out[index].title,
                                                 interpretedTitle: saved.spec.title,
                                                 criteria: criteria, members: members)
            await store.upsert(albumInfo: info)
            out[index] = info
            Diagnostics.mark("aialbum.finalize: '\(criteria)' → members=\(members.count)")
        }
        return out
    }

    // MARK: - 作成 / 再設定 / 削除

    /// 作成/再設定（共通）。**0 件でも保存**する。戻り値: (結果, 更新後の AI アルバム一覧 or nil)。
    func make(id: String, title: String, criteria: String) async -> (result: AIAlbumResult, albums: [AutoAlbumInfo]?) {
        let trimmed = criteria.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (.empty, nil) }

        let now = Date()
        interpreter.remove(id: id)   // 再設定（検索文変更）は解釈からやり直す
        // 作成/編集は**即時プレビュー**（決定的レイヤーのみ・LLM なし＝1〜2 秒）。
        // FM 解釈＋LLM 審査つきの本番化は夜間（finalizePending・電源＋Wi-Fi＋ロック中）に行う。
        let namedPeople = await namedPeopleProvider?() ?? []
        var saved = AIAlbumInterpreter.previewInterpretation(criteria: trimmed, now: now,
                                                             namedPeople: namedPeople)
        let all = await store.allEnrichedPhotosLite()
        var (members, pool) = await rankedSearch(all, saved: saved, now: now)
        // 証拠ゲート（除外つきのみ）はプレビューでも適用（除外の精度は落とさない）。
        members = await verification.evidenceGatedIfExcluding(members, spec: saved.spec)
        saved.scoredPool = pool
        saved.evaluatedEmbedCount = await store.embeddedCount()
        interpreter.save(saved, for: id)
        Diagnostics.mark("aialbum.make: '\(trimmed)' all=\(all.count) members=\(members.count)")
        let info = AIAlbumSearcher.buildInfo(id: id, title: title, interpretedTitle: saved.spec.title,
                                             criteria: trimmed, members: members)
        await store.upsert(albumInfo: info)
        return (.created(info), await loadAll())
    }

    func delete(id: String) async -> [AutoAlbumInfo] {
        await store.deleteAlbum(id: id)
        interpreter.remove(id: id)
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
            var saved = await interpreter.interpretation(id: album.id, criteria: criteria, now: now)
            var (members, pool) = await rankedSearch(all, saved: saved, now: now)
            members = await verification.evidenceGatedIfExcluding(members, spec: saved.spec)
            members = await verification.verified(members, criteria: criteria)
            saved.scoredPool = pool
            saved.evaluatedEmbedCount = embedCount
            interpreter.save(saved, for: album.id)
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
                  var saved = interpreter.saved(for: album.id), saved.criteria == criteria,
                  saved.evaluatedEmbedCount > 0 else { continue }

            // ハード条件（相対日付は now で解決）を新規分に適用。
            var base = QueryEvaluator.hardFilter(newPhotos, spec: saved.spec, now: now,
                                                 peopleByRefKey: await peopleMapIfNeeded(for: saved.spec))
            saved.evaluatedEmbedCount += newRefKeys.count
            // 対策2: 人系の除外があれば顔の実測（faceCount>0）をハード除外（フル評価と同じ規則）。
            if let faceCounts = await faceCountsIfNeeded(for: saved.spec) {
                base = base.filter { (faceCounts[$0.id] ?? 0) == 0 }
            }
            guard !base.isEmpty else { interpreter.save(saved, for: album.id); continue }

            // 意味採点（クエリ埋め込みはキャッシュ）。埋め込み不可なら評価枚数だけ進める。
            guard let q = await queryVectors(for: saved) else {
                interpreter.save(saved, for: album.id)
                continue
            }
            var added: [String: Float] = [:]
            for photo in base {
                guard let data = newVectors[photo.id], let v = ClipMath.decode(data) else { continue }
                // 採点規則（max-over-probes＋除外の相対判定）はフル評価と同一（QueryEmbedder に一元化）。
                guard let pos = QueryEmbedder.semanticScore(q, photoVector: v) else { continue }
                added[photo.id] = pos
            }
            guard !added.isEmpty else { interpreter.save(saved, for: album.id); continue }

            saved.scoredPool = AIAlbumSearcher.mergePool(saved.scoredPool, adding: added)
            interpreter.save(saved, for: album.id)

            // 閾値を超えた新規だけメンバーへ追加（既存メンバーは維持・並びは日付降順で再構成）。
            let memberKeys = Set(AIAlbumSearcher.memberKeys(fromPool: saved.scoredPool))
            let existing = Set(album.memberRefs)
            let newlyIn = base.filter { memberKeys.contains($0.id) && !existing.contains($0.id) }
            guard !newlyIn.isEmpty else { continue }

            // P2: 増分の新規追加分も証拠ゲート → LLM 審査（小さいバッチ＝安価）。
            let gatedNew = await verification.evidenceGatedIfExcluding(newlyIn, spec: saved.spec)
            let verifiedNew = await verification.verified(gatedNew, criteria: criteria)
            guard !verifiedNew.isEmpty else { continue }
            let existingPhotos = await store.enrichedPhotos(forRefKeys: album.memberRefs)
            let members = (existingPhotos + verifiedNew)
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
        let evaluated = interpreter.minEvaluatedEmbedCount(for: current.map(\.id))
        guard embedCount - evaluated > threshold else { return nil }
        Diagnostics.mark("aialbum.drift: embedded=\(embedCount) evaluated=\(evaluated) → full refresh")
        return await refresh(current)
    }

    func clearCache() {
        interpreter.removeAll()
        queryVectorCache = [:]
    }

    /// 再解析（全埋め込み作り直し）時：解釈は保持し、評価状態だけリセットする。
    func resetEvaluationState() {
        interpreter.resetEvaluationStates()
        queryVectorCache = [:]
    }

    // MARK: - Private

    /// 増分評価用のクエリ埋め込み（肯定＋除外群）。フレーズ選定・埋め込みの規則は
    /// `QueryEmbedder` に集約（フル評価＝searchWithPool と**同一実装**）で、ここはキャッシュだけ持つ。
    private func queryVectors(for saved: SavedInterpretation) async -> QueryEmbedder.QueryVectors? {
        let include = saved.spec.allContentTerms.include
        let exclude = saved.spec.allContentTerms.exclude
        let phrase = QueryEmbedder.phrase(include: include, exclude: exclude,
                                          semanticText: saved.semanticText)
        guard !phrase.isEmpty else { return nil }
        let probes = saved.probes ?? []
        let cacheKey = "\(phrase)|\(probes.joined(separator: ","))|\(exclude.joined(separator: ","))"
        if let cached = queryVectorCache[cacheKey] { return cached }
        guard let result = await embedder.embed(phrase: phrase, probes: probes,
                                                excludeTerms: exclude) else { return nil }
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
        let probes = saved.probes ?? []
        let faceCounts = await faceCountsIfNeeded(for: spec)
        // 人物条件は焼き込みでなく live 人物名（PeopleEngine）で照合する（命名/統合の追従）。
        let peopleMap = await peopleMapIfNeeded(for: spec)
        // P1: タグ台帳（refKey → シーンタグ）。一次ランキングと離散除外に使う。
        let tags = await tagStore?.allTags() ?? [:]
        return await Task.detached(priority: .utility) {
            let (members, pool) = await searcher.searchWithPool(
                baseLite: allLite, spec: spec, now: now, semanticText: semanticText,
                probes: probes, faceCounts: faceCounts, photoTags: tags,
                peopleByRefKey: peopleMap,
                loadPage: { offset, limit in
                    await store.enrichmentVectorPage(offset: offset, limit: limit)
                })
            let sorted = members.sorted { ($0.captureDate ?? .distantPast) > ($1.captureDate ?? .distantPast) }
            return (sorted, pool)
        }.value
    }

    private func loadAll() async -> [AutoAlbumInfo] {
        (await store.allAlbums())
            .filter { $0.strategyID == AIAlbumStrategy.strategyID }
            .sorted { $0.representativeDate > $1.representativeDate }
    }
}
