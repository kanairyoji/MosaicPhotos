import Foundation
import os

/// AI アルバムの検索とアルバム情報の組み立て（純ロジック・テスト対象）。
/// 「日付/場所/人物などのハード条件 → 内容語のソフト絞り込み」で、内容語で全滅する場合は
/// ハード条件のみの結果に戻す（タグ未計算でも no-match にしない）。
struct AIAlbumSearcher {
    let textEmbedder: TextEmbedder?

    private static let log = Logger(subsystem: "com.mosaicphotos.AutoAlbum", category: "aialbum")
    /// 意味検索の絶対フロア（低め）。MobileCLIP-S2 の一致コサインは概ね 0.20〜0.30 と低く圧縮されており、
    /// 高い絶対しきい値だと全滅するため、明確な無関係（負・極小）だけを落とす低フロアにする。
    static let semanticFloor: Float = 0.20
    /// 上位帯マージン。最上位スコアからこの幅以内だけ採用（強いクエリほど絞り、弱いクエリは広めに）。
    static let semanticMargin: Float = 0.06
    /// 1 アルバムの最大採用数（コサインは弱分離なので上位 K 件で打ち切ってノイズの裾を切る）。
    static let maxResults = 50

    init(textEmbedder: TextEmbedder? = nil) {
        self.textEmbedder = textEmbedder
    }

    /// `semanticText` は英訳済みの自然文（CLIP 意味検索用）。空なら keywords を連結して使う。
    func search(_ all: [EnrichedPhoto], query: AIAlbumQuery, now: Date,
                semanticText: String = "") async -> [EnrichedPhoto] {
        // 構造化条件（場所/日付/人物/お気に入り/ソース）で絞る。
        let base = PhotoQueryEngine.filter(all, with: query, now: now)

        // 意味検索に使う英文（自然文）。語彙ゼロのオープン語彙 CLIP。空なら keywords を連結。
        let phrase = semanticText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? query.keywords.joined(separator: ", ")
            : semanticText
        guard !phrase.isEmpty, !base.isEmpty else { return base }

        // ハイブリッド：字句（地名/人物の固有名詞）＋ 意味（CLIP）を RRF で融合。
        let lexical = LexicalSearch.rank(base, keywords: query.keywords)

        var semantic: [EnrichedPhoto] = []
        if let textEmbedder, textEmbedder.isAvailable,
           let vector = await textEmbedder.embed(phrase) {
            // 各写真の生コサインを算出（分布をログするため SemanticRanker ではなく直接計算）。
            let scored = base.compactMap { photo -> (photo: EnrichedPhoto, score: Float)? in
                guard let data = photo.clipVector, let v = ClipMath.decode(data) else { return nil }
                return (photo, ClipMath.cosine(vector, v))
            }.sorted { $0.score > $1.score }
            // 低フロアで無関係を除外し、最上位から semanticMargin 以内の上位帯だけを、上位 K 件で打ち切る。
            if let top = scored.first?.score {
                let cutoff = max(Self.semanticFloor, top - Self.semanticMargin)
                semantic = scored.prefix(Self.maxResults).filter { $0.score >= cutoff }.map(\.photo)
            }
            let isASCII = phrase.allSatisfy(\.isASCII)
            let top = scored.first?.score ?? -1
            Self.log.notice("aialbum: phrase=\"\(phrase, privacy: .public)\" ascii=\(isASCII, privacy: .public) embedded=\(scored.count, privacy: .public) top=\(top, privacy: .public) kept=\(semantic.count, privacy: .public)")
            if !isASCII {
                Self.log.notice("aialbum: query not translated to English (non-ASCII); semantic match will be poor")
            }
        }

        let fused = HybridFusion.fuse([lexical, semantic].filter { !$0.isEmpty })
        if !fused.isEmpty { return fused }
        // 当たらなかった場合：構造化条件（場所/人物/期間/お気に入り）があればそれを返す。
        // 内容語だけ（構造化条件なし）で当たらないときに base＝全写真へフォールバックすると、
        // 無関係な写真（CLIP 未埋め込み＝タグなしも含む）が丸ごと入ってしまうため、空を返す。
        return query.hasStructuredConstraints ? base : []
    }

    /// バッチ版 `search`：clipVector(約138MB) を一度に載せず、`loadPage` で **ページ単位**に読みながら
    /// 各写真のコサインを算出する。スコア（Float）は全件保持しても軽いので、選抜ロジックは純関数版と
    /// **完全に同一**（同じ `sorted.prefix(maxResults).filter(≥cutoff)`）＝結果は一致する。
    /// - `all`: clipVector を載せない軽量メタデータ（構造化フィルタ・字句・カタログ用）。
    /// - `loadPage(offset, limit)`: `(refKey, clipVector)` のページを返す（空ページで終端）。
    func search(baseLite all: [EnrichedPhoto], query: AIAlbumQuery, now: Date, semanticText: String,
                pageSize: Int = 4000,
                loadPage: (_ offset: Int, _ limit: Int) async -> [(refKey: String, clipVector: Data)]
    ) async -> [EnrichedPhoto] {
        let base = PhotoQueryEngine.filter(all, with: query, now: now)

        let phrase = semanticText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? query.keywords.joined(separator: ", ")
            : semanticText
        guard !phrase.isEmpty, !base.isEmpty else { return base }

        let lexical = LexicalSearch.rank(base, keywords: query.keywords)

        var semantic: [EnrichedPhoto] = []
        if let textEmbedder, textEmbedder.isAvailable,
           let vector = await textEmbedder.embed(phrase) {
            let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // スコアは全件保持（Float のみ＝軽い）。clipVector はページごとに読んで都度解放する。
            var scored: [(photo: EnrichedPhoto, score: Float)] = []
            scored.reserveCapacity(base.count)
            var offset = 0
            while true {
                let page = await loadPage(offset, pageSize)
                if page.isEmpty { break }
                for entry in page {
                    guard let photo = baseByID[entry.refKey], let v = ClipMath.decode(entry.clipVector) else { continue }
                    scored.append((photo, ClipMath.cosine(vector, v)))
                }
                offset += pageSize
                if page.count < pageSize { break }
            }
            scored.sort { $0.score > $1.score }
            if let top = scored.first?.score {
                let cutoff = max(Self.semanticFloor, top - Self.semanticMargin)
                semantic = scored.prefix(Self.maxResults).filter { $0.score >= cutoff }.map(\.photo)
            }
            let isASCII = phrase.allSatisfy(\.isASCII)
            let top = scored.first?.score ?? -1
            Self.log.notice("aialbum: phrase=\"\(phrase, privacy: .public)\" ascii=\(isASCII, privacy: .public) embedded=\(scored.count, privacy: .public) top=\(top, privacy: .public) kept=\(semantic.count, privacy: .public)")
            if !isASCII {
                Self.log.notice("aialbum: query not translated to English (non-ASCII); semantic match will be poor")
            }
        }

        let fused = HybridFusion.fuse([lexical, semantic].filter { !$0.isEmpty })
        if !fused.isEmpty { return fused }
        return query.hasStructuredConstraints ? base : []
    }

    /// メンバー写真から AI アルバムの表示情報を組み立てる（純）。
    /// タイトルはユーザー指定を優先し、空なら解釈タイトル→条件文の順で補完する。
    static func buildInfo(id: String, title: String, query: AIAlbumQuery, criteria: String,
                          members: [EnrichedPhoto]) -> AutoAlbumInfo {
        let dates = members.compactMap(\.captureDate)
        let people = rankedByFrequency(members.flatMap(\.people))
        let located = members.filter(\.hasCoordinate)
        let lat = located.isEmpty ? nil : located.compactMap(\.latitude).reduce(0, +) / Double(located.count)
        let lon = located.isEmpty ? nil : located.compactMap(\.longitude).reduce(0, +) / Double(located.count)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = !trimmedTitle.isEmpty ? trimmedTitle : (query.title.isEmpty ? criteria : query.title)
        return AutoAlbumInfo(
            id: id, strategyID: AIAlbumStrategy.strategyID,
            title: resolved, placeName: resolved, places: [resolved], country: nil, people: people,
            startDate: dates.min() ?? .distantPast, endDate: dates.max() ?? .distantPast,
            coverRef: pickCoverRef(members), memberRefs: members.map(\.id), photoCount: members.count,
            representativeDate: dates.max() ?? Date(), latitude: lat, longitude: lon, criteria: criteria)
    }
}
