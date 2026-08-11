import Foundation
import MosaicSupport
import SwiftData

/// 写真ごとの**シーンタグ**（Vision 分類・約1,300クラス・精度校正済み）と **VLM キャプション**
/// （SmolVLM・任意）の永続化。AI アルバムの「タグ台帳＋LLM 審査」検索の一次データ。
///
/// CLIP の `AutoAlbumStore` とは**別コンテナ**（"TagsV1"・FacesV1 と同じパターン）＝
/// タグ機能の追加・スキーマ変更で既存の埋め込みデータを壊さない。
@Model
final class PhotoTagRecord {
    @Attribute(.unique) var refKey: String
    /// Vision 分類の識別子（英語・precision フィルタ済み・最大 ~10 個）。
    var tags: [String]
    /// VLM の短文キャプション（英語）。未生成は nil（タグより後から埋まる）。
    var caption: String?
    /// タグ付けロジックの版（分類器・しきい値変更時に採番して再タグ）。
    var version: Int
    /// 写真内テキスト（OCR）。未検出/未計測は nil。※ v2 で追加（optional＝軽量マイグレーション）
    var ocrText: String?
    /// 写っている人物の数（Vision 人物矩形）。未計測は nil。
    var humanCount: Int?
    /// 美的スコア（-1〜1・iOS 18+）。未計測は nil。
    var aesthetic: Double?

    init(refKey: String, tags: [String], caption: String? = nil, version: Int,
         ocrText: String? = nil, humanCount: Int? = nil, aesthetic: Double? = nil) {
        self.refKey = refKey
        self.tags = tags
        self.caption = caption
        self.version = version
        self.ocrText = ocrText
        self.humanCount = humanCount
        self.aesthetic = aesthetic
    }
}

/// タグ・キャプションの @ModelActor ストア。⚠️ 本番はオフメイン生成（@ModelActor は init した
/// スレッドで実行される・事例参照）。
@ModelActor
actor TagStore {
    private static let log = LogChannel(subsystem: "com.mosaicphotos.AutoAlbum", label: "Tags")

    /// 現行のタグ付け版。v2: OCR・動物・人物数・美的スコア・アセット種別タグを追加。
    /// v3: シーンタグを precision 0.75・最大 25 個へ拡大（検索インデックスは広めに・
    /// 表示は上位 10 のまま）＋ OCR の信頼度足切り。版上げで既存写真も夜間に再タグされる。
    static let currentVersion = 3

    static func makeContainer(isStoredInMemoryOnly: Bool = false) -> ModelContainer {
        let schema = Schema([PhotoTagRecord.self])
        if isStoredInMemoryOnly {
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return (try? ModelContainer(for: schema, configurations: [memory])) ?? (try! ModelContainer(for: schema))
        }
        return resilientModelContainer(name: "TagsV1", schema: schema) { Self.log.error($0) }
    }

    init(isStoredInMemoryOnly: Bool = false) {
        self.init(modelContainer: Self.makeContainer(isStoredInMemoryOnly: isStoredInMemoryOnly))
    }

    // MARK: - タグ付け進捗

    /// タグ付け済み（現行版）の refKey 集合。
    func taggedRefKeys() -> Set<String> {
        let v = Self.currentVersion
        let records = (try? modelContext.fetch(
            FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { $0.version >= v }))) ?? []
        return Set(records.map(\.refKey))
    }

    func taggedCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<PhotoTagRecord>())) ?? 0
    }

    /// タグの頻度上位（識別子・降順）。AI アルバム作成のサジェストチップ
    /// （「よく写るもの」＝頻出タグ∩レキシコンの日本語表示）に使う。
    func topTags(limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        let records = (try? modelContext.fetch(FetchDescriptor<PhotoTagRecord>())) ?? []
        for record in records {
            for tag in record.tags { counts[tag, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    func captionedCount() -> Int {
        (try? modelContext.fetchCount(
            FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { $0.caption != nil }))) ?? 0
    }

    /// キャプション済みの (refKey, caption) を先頭から最大 limit 件返す（確認 UI 用）。
    func captionedSamples(limit: Int) -> [(refKey: String, caption: String)] {
        var d = FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { $0.caption != nil },
                                                sortBy: [SortDescriptor(\.refKey)])
        d.fetchLimit = limit
        return ((try? modelContext.fetch(d)) ?? []).compactMap { r in
            guard let c = r.caption, !c.isEmpty else { return nil }
            return (refKey: r.refKey, caption: c)
        }
    }

    /// バッチ記録（save は 1 回）。既存レコードは更新（版を上げて再タグした場合も上書き）。
    /// キャプションは触らない（v1 → v2 の再タグで生成済みキャプションを消さない）。
    func recordTags(_ batch: [(refKey: String, info: PhotoSenseInfo)]) {
        for entry in batch {
            let key = entry.refKey
            var d = FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { $0.refKey == key })
            d.fetchLimit = 1
            if let existing = try? modelContext.fetch(d).first {
                existing.tags = entry.info.tags
                existing.ocrText = entry.info.ocrText
                existing.humanCount = entry.info.humanCount
                existing.aesthetic = entry.info.aesthetic
                existing.version = Self.currentVersion
            } else {
                modelContext.insert(PhotoTagRecord(refKey: key, tags: entry.info.tags,
                                                   version: Self.currentVersion,
                                                   ocrText: entry.info.ocrText,
                                                   humanCount: entry.info.humanCount,
                                                   aesthetic: entry.info.aesthetic))
            }
        }
        try? modelContext.save()
    }

    // MARK: - キャプション（VLM・タグより後から埋まる）

    /// 既存キャプションを全消去する（VLM モデル差し替え時＝`captionModelVersion` 変更で 1 回）。
    /// caption を nil に戻すと `captionPending` が再び対象にし、新モデルで付け直される。
    func resetCaptions() -> Int {
        guard let records = try? modelContext.fetch(
            FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { $0.caption != nil })) else { return 0 }
        for r in records { r.caption = nil }
        try? modelContext.save()
        return records.count
    }

    /// キャプション未生成（caption == nil）の件数。インターリーブの進捗判定に使う。
    /// `favorites` 指定時はその集合内のみ数える（キャプションはお気に入り限定のため）。
    func captionPendingCount(favorites: Set<String>? = nil) -> Int {
        if let favorites {
            guard !favorites.isEmpty else { return 0 }
            return (try? modelContext.fetchCount(FetchDescriptor<PhotoTagRecord>(
                predicate: #Predicate { favorites.contains($0.refKey) && $0.caption == nil }))) ?? 0
        }
        return (try? modelContext.fetchCount(
            FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { $0.caption == nil }))) ?? 0
    }

    /// キャプション未生成（タグ付けは済み＝レコードあり）の refKey **集合**を返す。
    /// `favorites` 指定時はその集合内のみ（キャプションはお気に入り限定のため）。
    /// 処理順（新しい順）は呼び出し側が撮影日で並べる（本ストアは日付を持たない）。
    func captionPendingSet(favorites: Set<String>? = nil) -> Set<String> {
        let d: FetchDescriptor<PhotoTagRecord>
        if let favorites {
            guard !favorites.isEmpty else { return [] }
            d = FetchDescriptor<PhotoTagRecord>(
                predicate: #Predicate { favorites.contains($0.refKey) && $0.caption == nil })
        } else {
            d = FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { $0.caption == nil })
        }
        return Set(((try? modelContext.fetch(d)) ?? []).map(\.refKey))
    }

    func recordCaptions(_ batch: [(refKey: String, caption: String)]) {
        for entry in batch {
            let key = entry.refKey
            var d = FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { $0.refKey == key })
            d.fetchLimit = 1
            if let existing = try? modelContext.fetch(d).first {
                existing.caption = entry.caption
            } else {
                modelContext.insert(PhotoTagRecord(refKey: key, tags: [],
                                                   caption: entry.caption, version: 0))
            }
        }
        try? modelContext.save()
    }

    // MARK: - 検索用の取り出し

    /// 指定 refKey 群のタグ（IN 句・検索の候補評価用）。
    func tags(forRefKeys keys: [String]) -> [String: [String]] {
        guard !keys.isEmpty else { return [:] }
        let set = keys
        let records = (try? modelContext.fetch(
            FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { set.contains($0.refKey) }))) ?? []
        var out: [String: [String]] = [:]
        for r in records where !r.tags.isEmpty { out[r.refKey] = r.tags }
        return out
    }

    /// **このライブラリに実在する**シーンタグの語彙（出現頻度の多い順）。
    ///
    /// クエリ語の接地先（ADR-101）。理論上の Vision 約1,300クラスではなく、実際に台帳へ出た語を使う
    /// ——ユーザーの写真に無い概念へ展開しても当たらないし、語彙が小さいほど接地も速い。
    /// - Parameter minCount: これ未満しか出現しないタグは語彙に入れない（誤タグの裾を切る）。
    /// - Parameter limit: 上限（接地は語彙数ぶんのコサインなので有界にする）。
    func tagVocabulary(minCount: Int = 3, limit: Int = 600) -> [String] {
        let records = (try? modelContext.fetch(FetchDescriptor<PhotoTagRecord>())) ?? []
        var freq: [String: Int] = [:]
        for r in records {
            for tag in r.tags { freq[tag.lowercased(), default: 0] += 1 }
        }
        return freq.filter { $0.value >= minCount }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    /// 指定 refKey の humanCount（証拠ゲート用・未計測はキーごと含めない・ADR-100）。
    func humanCounts(forRefKeys keys: [String]) -> [String: Int] {
        guard !keys.isEmpty else { return [:] }
        let set = keys
        let records = (try? modelContext.fetch(
            FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { set.contains($0.refKey) }))) ?? []
        var out: [String: Int] = [:]
        for r in records {
            if let count = r.humanCount { out[r.refKey] = count }
        }
        return out
    }

    /// 全タグ台帳（refKey → tags）。検索の一次ランキングで使う（数万件・値は小さい）。
    func allTags() -> [String: [String]] {
        let records = (try? modelContext.fetch(FetchDescriptor<PhotoTagRecord>())) ?? []
        var out: [String: [String]] = [:]
        out.reserveCapacity(records.count)
        for r in records where !r.tags.isEmpty { out[r.refKey] = r.tags }
        return out
    }

    /// 全 humanCount 台帳（refKey → 上半身検出の人数）。**未計測の写真はキーごと含めない**。
    ///
    /// ⚠️ 「人が写っていない」の判定はこれを主軸にする（ADR-100）。顔スキャン（`FaceStore`）は
    /// 実機で網羅率 11% しかなく、`?? 0` で未スキャンを「人なし」と読んでいたため、
    /// 除外つきアルバムの半分が人物写真になっていた（COCO 計測: precision 0.490・誤混入 2062 枚）。
    /// `humanCount` は夜間タグ付けパスで既に計算・保存済みで網羅率は約 86%、しかも上半身検出なので
    /// 後ろ姿や小さい顔も拾える＝「人がいない」の担保に適する。新たな計算は不要。
    func allHumanCounts() -> [String: Int] {
        let records = (try? modelContext.fetch(
            FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { $0.humanCount != nil }))) ?? []
        var out: [String: Int] = [:]
        out.reserveCapacity(records.count)
        for r in records {
            if let count = r.humanCount { out[r.refKey] = count }
        }
        return out
    }

    /// 全 OCR 台帳（refKey → 写真内テキスト・非空のみ）。字句検索（LexicalSearch）用。
    func allOcrTexts() -> [String: String] {
        let records = (try? modelContext.fetch(
            FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { $0.ocrText != nil }))) ?? []
        var out: [String: String] = [:]
        for r in records { if let t = r.ocrText, !t.isEmpty { out[r.refKey] = t } }
        return out
    }

    /// 指定 refKey 群の OCR テキスト（フル画像の情報パネル用）。
    func ocrTexts(forRefKeys keys: [String]) -> [String: String] {
        guard !keys.isEmpty else { return [:] }
        let set = keys
        let records = (try? modelContext.fetch(
            FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { set.contains($0.refKey) }))) ?? []
        var out: [String: String] = [:]
        for r in records { if let t = r.ocrText, !t.isEmpty { out[r.refKey] = t } }
        return out
    }

    /// 指定 refKey 群の美的スコア（カバー選択用）。
    func aesthetics(forRefKeys keys: [String]) -> [String: Double] {
        guard !keys.isEmpty else { return [:] }
        let set = keys
        let records = (try? modelContext.fetch(
            FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { set.contains($0.refKey) }))) ?? []
        var out: [String: Double] = [:]
        for r in records { if let a = r.aesthetic { out[r.refKey] = a } }
        return out
    }

    /// 美的スコアの全台帳（refKey → スコア・「ベストショット」フィルタ用）。
    /// スコア未付与（nil＝未解析）は含めない。分布適応しきい値の算出に全件が要る。
    func allAesthetics() -> [String: Double] {
        var d = FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { $0.aesthetic != nil })
        d.propertiesToFetch = [\.refKey, \.aesthetic]
        let records = (try? modelContext.fetch(d)) ?? []
        var out: [String: Double] = [:]
        out.reserveCapacity(records.count)
        for r in records { if let a = r.aesthetic { out[r.refKey] = a } }
        return out
    }

    /// 指定 refKey 群のキャプション（LLM Verify の入力用）。
    func captions(forRefKeys keys: [String]) -> [String: String] {
        guard !keys.isEmpty else { return [:] }
        let set = keys
        let records = (try? modelContext.fetch(
            FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { set.contains($0.refKey) }))) ?? []
        var out: [String: String] = [:]
        for r in records { if let c = r.caption { out[r.refKey] = c } }
        return out
    }

    func reset() {
        try? modelContext.delete(model: PhotoTagRecord.self)
        try? modelContext.save()
    }
}
