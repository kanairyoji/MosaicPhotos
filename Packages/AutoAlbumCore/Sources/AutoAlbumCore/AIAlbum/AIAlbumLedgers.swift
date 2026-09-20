import Foundation

/// 1 回の処理（再評価・掃除・増分）の中で、**アルバムをまたいで共有する台帳のスナップショット**。
///
/// ⚠️ なぜ要るか（ADR-119 の形そのもの）: タグ台帳（`PhotoTagRecord`）の全件読み出しは
/// ライブラリ規模に比例する（実機 8.6 万行）。アルバムのループの中で `allTags` / `allOcrTexts` /
/// `allHumanCounts` / `allAesthetics` を呼ぶと、**アルバム 1 本につき 8.6 万行 × 数回**になる。
/// 「1 回ぶんに見える呼び出し」が、実は写真数 × アルバム数に比例していた。
///
/// 写真の台帳（`allEnrichedPhotosLite`）とカタログは diagnostics-48 でループの外へ出たが、
/// **タグ側だけ取り残されていた**（`pruneAfterPeopleChange` が名前表だけを 1 回で共有している
/// のが、意図としては正しく、範囲が足りていなかった証拠）。
///
/// 規則は 2 つだけ。
/// 1. **遅延**に取る。条件を持つアルバムが 1 本も無ければ 1 回も読まない（従来の性質を保つ
///    ——`allHumanCounts` は人系の除外があるときだけ、`allAesthetics` は美的条件があるときだけ）。
/// 2. **1 回の処理の中でだけ**生かす。跨いで持ち回らない（夜間に台帳が育つので、次の処理は
///    次のスナップショットで見る）。
///
/// 取得中の重複も防ぐ（値でなく `Task` を控える）。MainActor 上なので、控える代入は最初の
/// suspension より前に必ず終わる＝2 本目の呼び出しが同じ fetch を始めることはない。
@MainActor
final class AIAlbumLedgers {
    private let tagStore: TagStore?
    private var tagsTask: Task<[String: [String]], Never>?
    private var ocrTask: Task<[String: String], Never>?
    private var humanCountsTask: Task<[String: Int], Never>?
    private var aestheticsTask: Task<[String: Double], Never>?

    init(tagStore: TagStore?) {
        self.tagStore = tagStore
    }

    /// 全タグ台帳（refKey → シーンタグ）。一次ランキングと離散除外に使う。
    func tags() async -> [String: [String]] {
        if let tagsTask { return await tagsTask.value }
        let store = tagStore
        let task = Task { await store?.allTags() ?? [:] }
        tagsTask = task
        return await task.value
    }

    /// 全 OCR 台帳（refKey → 写真内テキスト）。字句検索チャネルへ。
    func ocrTexts() async -> [String: String] {
        if let ocrTask { return await ocrTask.value }
        let store = tagStore
        let task = Task { await store?.allOcrTexts() ?? [:] }
        ocrTask = task
        return await task.value
    }

    /// 全 humanCount 台帳（refKey → 上半身検出の人数）。人物証拠（ADR-100）と人数条件（S12）。
    func humanCounts() async -> [String: Int] {
        if let humanCountsTask { return await humanCountsTask.value }
        let store = tagStore
        let task = Task { await store?.allHumanCounts() ?? [:] }
        humanCountsTask = task
        return await task.value
    }

    /// 全美的スコア台帳（refKey → -1〜1）。「綺麗な写真」条件の分布適応しきい値に使う。
    func aesthetics() async -> [String: Double] {
        if let aestheticsTask { return await aestheticsTask.value }
        let store = tagStore
        let task = Task { await store?.allAesthetics() ?? [:] }
        aestheticsTask = task
        return await task.value
    }
}
