import Foundation
import MosaicSupport
import SwiftData

/// 付加情報（PhotoEnrichment）と生成アルバム（GeneratedAlbum）の永続化を司る ModelActor。
/// `@ModelActor` により ModelContext がアクタ専用 executor に束縛される（メイン生成→オフメイン使用の
/// "Unbinding from the main queue" 警告と非 Sendable 競合を回避）。
/// `@Model` は actor 外へ漏らさず、必ず Sendable 値（`EnrichedPhoto` / `AutoAlbumInfo`）に変換して返す。
@ModelActor
actor AutoAlbumStore {
    private static let log = LogChannel(subsystem: "com.mosaicphotos.AutoAlbum", label: "AutoAlbum")

    /// 名前付き設定でコンテナを作る（他コンテナとの衝突回避・"AutoAlbumV9" は破棄採番＝
    /// OCR/固定語彙タグ列を撤去し CLIP 埋め込み中心へ移行したスキーマ変更に伴う再構築）。失敗時はインメモリ。
    static func makeContainer(isStoredInMemoryOnly: Bool = false) -> ModelContainer {
        let schema = Schema([PhotoEnrichment.self, GeneratedAlbum.self, PhotoEmbedding.self])
        if isStoredInMemoryOnly {
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return (try? ModelContainer(for: schema, configurations: [memory])) ?? (try! ModelContainer(for: schema))
        }
        // "AutoAlbumV10" は破棄採番：CLIP 埋め込みを PhotoEnrichment から別テーブル PhotoEmbedding
        // （Float16）へ分離したスキーマ変更に伴う再構築。旧 V9 ストアは破棄され埋め込みは再生成される。
        return makeResilientContainer(name: "AutoAlbumV10", schema: schema) { Self.log.error($0) }
    }

    /// 名前付き永続コンテナを作る。壊れた/非互換ストアで失敗したら **store ファイルを削除して作り直し**
    /// （自己修復）、それでも駄目ならインメモリへ。SwiftData が trap せず必ず ModelContainer を返すことで、
    /// 起動時に壊れたストアでクラッシュするのを防ぐ（データは失うが回復＝再構築される）。
    /// 実体は MosaicSupport の共通ロジック。TagStore / FaceStore もこの窓口を共用する。
    static func makeResilientContainer(name: String, schema: Schema, log: (String) -> Void) -> ModelContainer {
        makeResilientModelContainer(
            name: name, schema: schema,
            openFailedMessage: "ModelContainer '\(name)' open failed; deleting store and rebuilding (data reset).",
            memoryFallbackMessage: "ModelContainer '\(name)' still failing; using in-memory store.",
            log: log)
    }

    /// 既存呼び出し（`AutoAlbumStore()` / `AutoAlbumStore(isStoredInMemoryOnly:)`）を維持する委譲 init。
    init(isStoredInMemoryOnly: Bool = false) {
        self.init(modelContainer: Self.makeContainer(isStoredInMemoryOnly: isStoredInMemoryOnly))
    }

    // MARK: - Enrichment

    /// 付加情報済みの全 refKey（差分判定用）。refKey 列のみを取得して他カラムを展開しない。
    func enrichedRefKeys() -> Set<String> {
        var descriptor = FetchDescriptor<PhotoEnrichment>()
        descriptor.propertiesToFetch = [\.refKey]
        let records = (try? modelContext.fetch(descriptor)) ?? []
        return Set(records.map(\.refKey))
    }

    /// バッチ書き込みの単位。大量 upsert でも登録オブジェクトが際限なく溜まらないよう、
    /// この件数ごとに**使い捨ての ModelContext** で save し、チャンク完了でその context ごと
    /// 解放して常駐メモリを有界に保つ（C2）。
    private static let writeChunk = AutoAlbumTuning.upsertWriteChunk

    /// 付加情報を upsert する（メタデータのみ・埋め込みは別テーブル）。
    /// kind/localIdentifier/cloudPath は refKey から導出する。大量挿入でも常駐が増えないよう
    /// `writeChunk` 件ごとに使い捨て context を作って save し、登録オブジェクトを解放する。
    func upsert(_ photos: [EnrichedPhoto]) {
        guard !photos.isEmpty else { return }
        var index = 0
        while index < photos.count {
            let end = min(index + Self.writeChunk, photos.count)
            // チャンク単位の使い捨て context。スコープを抜けると登録済み @Model が解放される。
            let ctx = ModelContext(modelContainer)
            for photo in photos[index..<end] {
                let key = photo.id
                let descriptor = FetchDescriptor<PhotoEnrichment>(predicate: #Predicate { $0.refKey == key })
                let ref = PhotoRef.decode(key)
                if let existing = try? ctx.fetch(descriptor).first {
                    existing.captureDate = photo.captureDate
                    existing.latitude = photo.latitude
                    existing.longitude = photo.longitude
                    existing.placeName = photo.placeName
                    existing.country = photo.country
                    existing.linkKey = photo.linkKey
                    existing.isScreenshot = photo.isScreenshot
                    existing.isFavorite = photo.isFavorite
                    existing.aspect = photo.aspect
                    existing.people = photo.people
                    existing.enrichedAt = Date()
                } else {
                    ctx.insert(PhotoEnrichment(
                        refKey: key, kind: ref?.isLocal == true ? "local" : "cloud",
                        localIdentifier: ref?.localIdentifier, cloudPath: ref?.cloudPath,
                        captureDate: photo.captureDate, latitude: photo.latitude, longitude: photo.longitude,
                        placeName: photo.placeName, country: photo.country, linkKey: photo.linkKey,
                        isScreenshot: photo.isScreenshot, isFavorite: photo.isFavorite,
                        aspect: photo.aspect, people: photo.people))
                }
            }
            try? ctx.save()
            index = end
        }
    }

    /// 既存のローカル付加情報の linkKey を、最新のバックアップ対応で更新する
    /// （エンリッチ後にバックアップ完了したケースで dedup を正しく保つため）。
    func refreshLocalLinkKeys(_ map: [String: String]) {
        let descriptor = FetchDescriptor<PhotoEnrichment>(predicate: #Predicate { $0.kind == "local" })
        guard let records = try? modelContext.fetch(descriptor) else { return }
        var changed = false
        for record in records {
            let newLink = record.localIdentifier.flatMap { map[$0] }
            if record.linkKey != newLink { record.linkKey = newLink; changed = true }
        }
        if changed { try? modelContext.save() }
    }

    /// 現存しない（削除/退避された）写真の付加情報を削除する。対応する埋め込み（PhotoEmbedding）も
    /// 孤児にならないよう同時に削除する。
    func prune(keeping refKeys: Set<String>) {
        guard let records = try? modelContext.fetch(FetchDescriptor<PhotoEnrichment>()) else { return }
        var removed: [String] = []
        for record in records where !refKeys.contains(record.refKey) {
            removed.append(record.refKey)
            modelContext.delete(record)
        }
        for key in removed {
            let d = FetchDescriptor<PhotoEmbedding>(predicate: #Predicate { $0.refKey == key })
            if let emb = try? modelContext.fetch(d).first { modelContext.delete(emb) }
        }
        try? modelContext.save()
    }

    /// 付加情報済みの全写真（戦略の入力）。埋め込みは別テーブルなので、この fetch は
    /// メタデータのみで軽量（巨大 blob を一切載せない）。
    func allEnrichedPhotosLite() -> [EnrichedPhoto] {
        // R4: 8.5万件の @Model を一括 materialize するとメモリがスパイクするため、**使い捨て
        // ModelContext でページ fetch→値型化→破棄**し、materialize を 1 ページに有界化する。
        // 蓄積するのは軽量な値型（EnrichedPhoto）だけ。直前の prune/更新を見るよう save 済みにする。
        try? modelContext.save()
        let pageSize = 5000
        var result: [EnrichedPhoto] = []
        var offset = 0
        while true {
            let ctx = ModelContext(modelContainer)   // ページごとに破棄して materialize を解放
            var descriptor = FetchDescriptor<PhotoEnrichment>(sortBy: [SortDescriptor(\.refKey)])
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = pageSize
            let records = (try? ctx.fetch(descriptor)) ?? []
            if records.isEmpty { break }
            result.append(contentsOf: records.map(\.asEnrichedPhoto))
            offset += records.count
            if records.count < pageSize { break }
        }
        return result
    }

    /// 意味検索のバッチ化用：埋め込み（PhotoEmbedding）を **page 単位**で `(refKey, clipVector)` として
    /// 取り出す。保存は Float16 だが、ここで fp32 LE（`ClipMath` が解釈する形式）へ復元して返すため
    /// 下流（`AIAlbumSearcher` / `ClipMath.decode`）は変更不要。`refKey` 昇順で安定ページング。
    /// 1ページ分（例 4,000 件）だけをメモリに置くために使う。
    func enrichmentVectorPage(offset: Int, limit: Int) -> [(refKey: String, clipVector: Data)] {
        var descriptor = FetchDescriptor<PhotoEmbedding>(sortBy: [SortDescriptor(\.refKey)])
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        let records = (try? modelContext.fetch(descriptor)) ?? []
        return records.compactMap { rec in
            guard let floats = ClipMath.decodeHalf(rec.vector) else { return nil }
            return (refKey: rec.refKey, clipVector: ClipMath.encode(floats))
        }
    }

    /// 増分評価用：指定 refKey 群の埋め込みだけを取り出す（fp32 復元済み）。
    /// 新規に埋め込まれた写真だけを採点するため、全ページ走査を避ける。
    func vectors(forRefKeys keys: [String]) -> [String: Data] {
        guard !keys.isEmpty else { return [:] }
        let set = keys
        let descriptor = FetchDescriptor<PhotoEmbedding>(predicate: #Predicate { set.contains($0.refKey) })
        let records = (try? modelContext.fetch(descriptor)) ?? []
        var out: [String: Data] = [:]
        for rec in records {
            guard let floats = ClipMath.decodeHalf(rec.vector) else { continue }
            out[rec.refKey] = ClipMath.encode(floats)
        }
        return out
    }

    /// 増分評価用：指定 refKey 群の付加情報（メタのみ・埋め込みなし）を取り出す。
    func enrichedPhotos(forRefKeys keys: [String]) -> [EnrichedPhoto] {
        guard !keys.isEmpty else { return [] }
        let set = keys
        let descriptor = FetchDescriptor<PhotoEnrichment>(predicate: #Predicate { set.contains($0.refKey) })
        let records = (try? modelContext.fetch(descriptor)) ?? []
        return records.map(\.asEnrichedPhoto)
    }

    func enrichmentCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<PhotoEnrichment>())) ?? 0
    }

    /// 単一 refKey の付加情報＋埋め込み試行済みフラグ（フル画像ビューの情報・状態表示用）。
    /// 表示タグ用に埋め込みを別テーブルから1件だけ読み、fp32 へ復元して合成する（単件なので軽い）。
    func insightRecord(refKey: String) -> (photo: EnrichedPhoto, tagged: Bool)? {
        let descriptor = FetchDescriptor<PhotoEnrichment>(predicate: #Predicate { $0.refKey == refKey })
        guard let record = try? modelContext.fetch(descriptor).first else { return nil }
        var photo = record.asEnrichedPhoto
        let embDesc = FetchDescriptor<PhotoEmbedding>(predicate: #Predicate { $0.refKey == refKey })
        if let emb = try? modelContext.fetch(embDesc).first, let floats = ClipMath.decodeHalf(emb.vector) {
            photo = photo.withClipVector(ClipMath.encode(floats))
        }
        return (photo, record.sceneTagged)
    }

    // MARK: - Perception (CLIP 埋め込み・バックグラウンド増分付与。ローカル/クラウド両対応)

    /// 全写真の sceneTagged を false に戻し、再埋め込みの対象にする
    /// （知覚ロジック改善時に、メタデータ・地名解決を保持したまま埋め込みだけ付け直す）。戻り値は対象件数。
    @discardableResult
    func resetSceneTagged() -> Int {
        guard let records = try? modelContext.fetch(FetchDescriptor<PhotoEnrichment>()) else { return 0 }
        for record in records { record.sceneTagged = false }
        try? modelContext.save()
        return records.count
    }

    /// 全写真の認識結果（CLIP 埋め込み）を完全に消去し、未処理に戻す。
    /// 「再解析」用。メタデータ（日付・場所・人物）は保持する。戻り値は対象件数。
    @discardableResult
    func clearPerception() -> Int {
        guard let records = try? modelContext.fetch(FetchDescriptor<PhotoEnrichment>()) else { return 0 }
        for record in records { record.sceneTagged = false }
        // 埋め込みは別テーブルごと削除する。
        for emb in (try? modelContext.fetch(FetchDescriptor<PhotoEmbedding>())) ?? [] {
            modelContext.delete(emb)
        }
        try? modelContext.save()
        return records.count
    }

    /// 埋め込み済み写真の数（進捗表示用）。
    func embeddedCount() -> Int {
        let descriptor = FetchDescriptor<PhotoEnrichment>(predicate: #Predicate { $0.sceneTagged == true })
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    /// まだ埋め込みしていない写真の総数（進捗ログ用）。
    func unembeddedCount() -> Int {
        let descriptor = FetchDescriptor<PhotoEnrichment>(predicate: #Predicate { $0.sceneTagged == false })
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    /// まだ埋め込みしていない写真の refKey（最大 limit 件・ローカル/クラウド両方）。
    /// 未埋め込みの refKey をバッチで返す。`localOnly` のときは**ローカル写真（"L-" 前缀）だけ**を
    /// DB 側で絞り込む（回線NG時にクラウド分＝サムネDLを避けてローカルだけ進めるため）。
    func unembeddedRefKeys(limit: Int, localOnly: Bool = false) -> [String] {
        let predicate: Predicate<PhotoEnrichment> = localOnly
            ? #Predicate { $0.sceneTagged == false && $0.refKey.starts(with: "L-") }
            : #Predicate { $0.sceneTagged == false }
        var descriptor = FetchDescriptor<PhotoEnrichment>(predicate: predicate)
        descriptor.fetchLimit = limit
        let records = (try? modelContext.fetch(descriptor)) ?? []
        return records.map(\.refKey)
    }

    /// refKey → 埋め込み を反映する（取得不可でも sceneTagged を立てる＝処理済み）。
    /// 埋め込みは fp32 で渡ってくるので Float16 にパックして別テーブル `PhotoEmbedding` へ upsert する。
    func applyPerception(_ byRefKey: [String: PhotoPerception]) {
        for (refKey, perception) in byRefKey {
            let descriptor = FetchDescriptor<PhotoEnrichment>(predicate: #Predicate { $0.refKey == refKey })
            guard let record = try? modelContext.fetch(descriptor).first else { continue }
            record.sceneTagged = true
            guard let fp32 = perception.clipVector, let floats = ClipMath.decode(fp32) else { continue }
            let half = ClipMath.encodeHalf(floats)
            let embDesc = FetchDescriptor<PhotoEmbedding>(predicate: #Predicate { $0.refKey == refKey })
            if let existing = try? modelContext.fetch(embDesc).first {
                existing.vector = half
            } else {
                modelContext.insert(PhotoEmbedding(refKey: refKey, vector: half))
            }
        }
        try? modelContext.save()
    }

    // MARK: - Albums

    func replaceAlbums(_ infos: [AutoAlbumInfo]) {
        if let existing = try? modelContext.fetch(FetchDescriptor<GeneratedAlbum>()) {
            for album in existing { modelContext.delete(album) }
        }
        for info in infos { insert(info) }
        try? modelContext.save()
    }

    /// 指定戦略のアルバムだけを差し替える（他戦略のアルバムは保持）。
    /// フォルダ名アルバムを時間＋場所アルバムと独立に更新するために使う。
    func replaceAlbums(forStrategy strategyID: String, with infos: [AutoAlbumInfo]) {
        let descriptor = FetchDescriptor<GeneratedAlbum>(predicate: #Predicate { $0.strategyID == strategyID })
        if let existing = try? modelContext.fetch(descriptor) {
            for album in existing { modelContext.delete(album) }
        }
        for info in infos { insert(info) }
        try? modelContext.save()
    }

    /// 単一アルバムを upsert する（同一 id があれば置換）。AI アルバムの保存に使う。
    func upsert(albumInfo info: AutoAlbumInfo) {
        deleteAlbum(id: info.id, save: false)
        insert(info)
        try? modelContext.save()
    }

    func deleteAlbum(id: String, save: Bool = true) {
        let descriptor = FetchDescriptor<GeneratedAlbum>(predicate: #Predicate { $0.id == id })
        if let existing = try? modelContext.fetch(descriptor) {
            for album in existing { modelContext.delete(album) }
        }
        if save { try? modelContext.save() }
    }

    private func insert(_ info: AutoAlbumInfo) {
        modelContext.insert(GeneratedAlbum(
            id: info.id, strategyID: info.strategyID, title: info.title, placeName: info.placeName,
            places: info.places, country: info.country, people: info.people,
            startDate: info.startDate, endDate: info.endDate, coverRef: info.coverRef,
            memberRefs: info.memberRefs, photoCount: info.photoCount,
            representativeDate: info.representativeDate,
            latitude: info.latitude, longitude: info.longitude, criteria: info.criteria))
    }

    /// 生成アルバム一覧（新しい順）。
    func allAlbums() -> [AutoAlbumInfo] {
        let records = (try? modelContext.fetch(FetchDescriptor<GeneratedAlbum>())) ?? []
        return records.map(\.asInfo).sorted { $0.representativeDate > $1.representativeDate }
    }

    // MARK: - Clearing

    func clearAll() {
        for record in (try? modelContext.fetch(FetchDescriptor<PhotoEnrichment>())) ?? [] { modelContext.delete(record) }
        for album in (try? modelContext.fetch(FetchDescriptor<GeneratedAlbum>())) ?? [] { modelContext.delete(album) }
        for emb in (try? modelContext.fetch(FetchDescriptor<PhotoEmbedding>())) ?? [] { modelContext.delete(emb) }
        try? modelContext.save()
    }
}
