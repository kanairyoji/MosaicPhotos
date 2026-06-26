import Foundation

/// AI アルバムの作成・再設定・削除・再評価をまとめた協調オブジェクト。
/// 状態（公開アルバム配列）はエンジンが持ち、本サービスは store を更新して最新の AI アルバム一覧を返す。
/// 解釈クエリはキャッシュし、語彙（地名/人物）が増えたら破棄して解釈し直す。
@MainActor
final class AIAlbumService {
    private let store: AutoAlbumStore
    private let understanding: QueryUnderstanding
    private let searcher: AIAlbumSearcher
    private let translator: QueryTranslator?
    private var queryCache: [String: AIAlbumQuery] = [:]
    private var lastCatalogSignature = -1

    init(store: AutoAlbumStore, understanding: QueryUnderstanding, textEmbedder: TextEmbedder?,
         translator: QueryTranslator? = nil) {
        self.store = store
        self.understanding = understanding
        self.translator = translator
        self.searcher = AIAlbumSearcher(textEmbedder: textEmbedder)
    }

    /// 任意言語の検索文を英語へ正規化（CLIP は英語学習のため）。translator 未提供なら原文。
    private func englishPhrase(_ text: String) async -> String {
        (await translator?.toEnglish(text)) ?? text
    }

    /// 作成/再設定（共通）。**0 件でも保存**する。戻り値: (結果, 更新後の AI アルバム一覧 or nil)。
    func make(id: String, title: String, criteria: String) async -> (result: AIAlbumResult, albums: [AutoAlbumInfo]?) {
        let trimmed = criteria.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (.empty, nil) }

        let now = Date()
        // clipVector を載せない軽量メタデータ（カタログ・構造化フィルタ用）。意味検索の埋め込みは
        // rankedSearch 内でページングして読む（約138MBの一括ロードを避ける）。
        let all = await store.allEnrichedPhotosLite()
        let catalog = AIAlbumCatalog.build(from: all)
        let query = await understanding.interpret(trimmed, catalog: catalog, now: now)
        queryCache[id] = query
        let members = await rankedSearch(all, query: query, semanticText: await englishPhrase(trimmed), now: now)
        let info = AIAlbumSearcher.buildInfo(id: id, title: title, query: query, criteria: trimmed, members: members)
        await store.upsert(albumInfo: info)
        return (.created(info), await loadAll())
    }

    func delete(id: String) async -> [AutoAlbumInfo] {
        await store.deleteAlbum(id: id)
        queryCache[id] = nil
        return await loadAll()
    }

    /// 保存済みアルバムを現在のインデックスで再評価（取り込み進行で中身が埋まる）。
    func refresh(_ current: [AutoAlbumInfo]) async -> [AutoAlbumInfo] {
        guard !current.isEmpty else { return current }
        let now = Date()
        // 軽量メタデータ（clipVector なし）。埋め込みは rankedSearch でページングして読む。
        let all = await store.allEnrichedPhotosLite()
        let catalog = AIAlbumCatalog.build(from: all)
        let signature = catalog.places.count &* 1000 &+ catalog.people.count
        if signature != lastCatalogSignature { queryCache.removeAll(); lastCatalogSignature = signature }

        var updated: [AutoAlbumInfo] = []
        for album in current {
            guard let criteria = album.criteria, !criteria.isEmpty else { updated.append(album); continue }
            let query: AIAlbumQuery
            if let cached = queryCache[album.id] {
                query = cached
            } else {
                query = await understanding.interpret(criteria, catalog: catalog, now: now)
                queryCache[album.id] = query
            }
            let members = await rankedSearch(all, query: query, semanticText: await englishPhrase(criteria), now: now)
            let info = AIAlbumSearcher.buildInfo(id: album.id, title: album.title, query: query,
                                                 criteria: criteria, members: members)
            await store.upsert(albumInfo: info)
            updated.append(info)
        }
        return updated.sorted { $0.representativeDate > $1.representativeDate }
    }

    func clearCache() {
        queryCache = [:]
        lastCatalogSignature = -1
    }

    // MARK: - Private

    private func rankedSearch(_ allLite: [EnrichedPhoto], query: AIAlbumQuery,
                              semanticText: String, now: Date) async -> [EnrichedPhoto] {
        // 意味検索の clipVector はストアからページ単位で読む（一度に全件を載せない）。
        let members = await searcher.search(
            baseLite: allLite, query: query, now: now, semanticText: semanticText,
            loadPage: { [store] offset, limit in
                await store.enrichmentVectorPage(offset: offset, limit: limit)
            })
        return members.sorted { ($0.captureDate ?? .distantPast) > ($1.captureDate ?? .distantPast) }
    }

    private func loadAll() async -> [AutoAlbumInfo] {
        (await store.allAlbums())
            .filter { $0.strategyID == AIAlbumStrategy.strategyID }
            .sorted { $0.representativeDate > $1.representativeDate }
    }
}
