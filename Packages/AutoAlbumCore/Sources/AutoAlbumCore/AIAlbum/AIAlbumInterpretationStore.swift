import Foundation
import PhotoSourceKit

/// AI アルバム 1 件分の**永続化された解釈＋増分評価の状態**。
///
/// 設計方針（根本見直し）: 解釈（検索文 → QuerySpec・英訳）は「検索文の性質」であり
/// 「ライブラリの性質」ではない。**作成/編集時に 1 回だけ LLM で解釈して保存**し、
/// 写真が増えても・カタログ（地名/人物の語彙）が変わっても解釈はやり直さない。
/// 存在しない地名・人名が解釈に含まれても、照合（QueryEvaluator）は部分一致なので
/// 該当写真が索引され次第、自動的に当たり始める。
public struct SavedInterpretation: Codable, Sendable {
    /// 解釈器（プロンプト）の版。プロンプト改善時に採番すると、保存済みの解釈が
    /// **次の評価時に 1 回だけ再解釈**される（旧 JSON は nil ＝ 旧版扱い）。
    /// v2: 例語のオウム返し・カタログ丸写しを禁止したプロンプト（2026-07）。
    /// v3: QuerySpecSanitizer（プレースホルダ除去・include/exclude 衝突解消）＋肯定フレーズの
    ///     否定節ストリップ（2026-07）。
    /// v4: P0＝日付は RelativeDateParser を唯一の出典に・place/people はカタログ/原文接地のみ・
    ///     翻訳失敗の非キャッシュ（2026-07）。
    /// v5: 決定的レキシコン（日本語視覚語＋人物否定）を解釈に注入（2026-07）。
    public static let currentVersion = 5
    public var version: Int?
    /// 解釈時の検索文（これが変わったときだけ再解釈する）。
    public var criteria: String
    /// LLM の解釈結果（相対日付は相対形のまま＝評価時に now で解決される）。
    public var spec: QuerySpec
    /// CLIP 用の英訳（LLM 翻訳の結果）。翻訳失敗時は **空**（日本語のまま CLIP に渡さない）。
    public var semanticText: String
    /// 翻訳が未完了（失敗）か。true なら次の評価時に翻訳だけ再試行する。
    public var translationPending: Bool?
    /// 増分評価: 意味スコアの上位プール（refKey → コサイン）。新規埋め込み分をここへマージする。
    public var scoredPool: [String: Float]
    /// 増分評価: 前回フル評価時点の埋め込み済み枚数（ドリフト検知＝差が開いたらフル再評価）。
    public var evaluatedEmbedCount: Int

    public init(criteria: String, spec: QuerySpec, semanticText: String,
                scoredPool: [String: Float] = [:], evaluatedEmbedCount: Int = 0) {
        self.version = Self.currentVersion
        self.criteria = criteria
        self.spec = spec
        self.semanticText = semanticText
        self.scoredPool = scoredPool
        self.evaluatedEmbedCount = evaluatedEmbedCount
    }
}

/// 解釈の永続ストア（アルバム id → SavedInterpretation）。
/// `JSONFileStore`（Caches 配下）を使い、**SwiftData のスキーマ変更なし**で永続化する
/// （@Model へのフィールド追加はコンテナ再作成＝埋め込みデータ全損になるため避ける）。
@MainActor
final class AIAlbumInterpretationStore {
    private let file = JSONFileStore<[String: SavedInterpretation]>(filename: "AIAlbumInterpretations.json")
    private var cache: [String: SavedInterpretation]?

    private var all: [String: SavedInterpretation] {
        if let cache { return cache }
        let loaded = file.load() ?? [:]
        cache = loaded
        return loaded
    }

    func get(_ id: String) -> SavedInterpretation? { all[id] }

    func set(_ id: String, _ value: SavedInterpretation) {
        var map = all
        map[id] = value
        cache = map
        file.save(map)
    }

    func remove(_ id: String) {
        var map = all
        map[id] = nil
        cache = map
        file.save(map)
    }

    func removeAll() {
        cache = [:]
        file.save([:])
    }

    /// 再解析（全埋め込み作り直し）用：**解釈は保持**しつつ評価状態（プール・評価済み枚数）だけ
    /// リセットする（LLM を再実行させないため removeAll とは分ける）。
    func resetEvaluationStates() {
        var map = all
        for (key, value) in map {
            var v = value
            v.scoredPool = [:]
            v.evaluatedEmbedCount = 0
            map[key] = v
        }
        cache = map
        file.save(map)
    }

    /// ドリフト検知用: 保存済み解釈のうち最小の evaluatedEmbedCount（未保存アルバムは 0 扱い）。
    func minEvaluatedEmbedCount(for ids: [String]) -> Int {
        ids.map { all[$0]?.evaluatedEmbedCount ?? 0 }.min() ?? 0
    }
}
