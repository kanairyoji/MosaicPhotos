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
        let schema = Schema([PhotoEnrichment.self, GeneratedAlbum.self])
        if isStoredInMemoryOnly {
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return (try? ModelContainer(for: schema, configurations: [memory])) ?? (try! ModelContainer(for: schema))
        }
        return makeResilientContainer(name: "AutoAlbumV9", schema: schema) { Self.log.error($0) }
    }

    /// 名前付き永続コンテナを作る。壊れた/非互換ストアで失敗したら **store ファイルを削除して作り直し**
    /// （自己修復）、それでも駄目ならインメモリへ。SwiftData が trap せず必ず ModelContainer を返すことで、
    /// 起動時に壊れたストアでクラッシュするのを防ぐ（データは失うが回復＝再構築される）。
    static func makeResilientContainer(name: String, schema: Schema, log: (String) -> Void) -> ModelContainer {
        let config = ModelConfiguration(name, schema: schema)
        if let container = try? ModelContainer(for: schema, configurations: [config]) { return container }
        log("ModelContainer '\(name)' open failed; deleting store and rebuilding (data reset).")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: config.url.path + suffix))
        }
        if let container = try? ModelContainer(for: schema, configurations: [config]) { return container }
        log("ModelContainer '\(name)' still failing; using in-memory store.")
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return (try? ModelContainer(for: schema, configurations: [memory])) ?? (try! ModelContainer(for: schema))
    }

    /// 既存呼び出し（`AutoAlbumStore()` / `AutoAlbumStore(isStoredInMemoryOnly:)`）を維持する委譲 init。
    init(isStoredInMemoryOnly: Bool = false) {
        self.init(modelContainer: Self.makeContainer(isStoredInMemoryOnly: isStoredInMemoryOnly))
    }

    // MARK: - Enrichment

    /// 付加情報済みの全 refKey（差分判定用）。
    func enrichedRefKeys() -> Set<String> {
        let records = (try? modelContext.fetch(FetchDescriptor<PhotoEnrichment>())) ?? []
        return Set(records.map(\.refKey))
    }

    /// 付加情報を upsert する。kind/localIdentifier/cloudPath は refKey から導出する。
    func upsert(_ photos: [EnrichedPhoto]) {
        for photo in photos {
            let key = photo.id
            let descriptor = FetchDescriptor<PhotoEnrichment>(predicate: #Predicate { $0.refKey == key })
            let ref = PhotoRef.decode(key)
            if let existing = try? modelContext.fetch(descriptor).first {
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
                // 埋め込みは計算済みのときだけ更新（空で上書きしない）。
                if photo.clipVector != nil { existing.clipVector = photo.clipVector }
                existing.enrichedAt = Date()
            } else {
                modelContext.insert(PhotoEnrichment(
                    refKey: key, kind: ref?.isLocal == true ? "local" : "cloud",
                    localIdentifier: ref?.localIdentifier, cloudPath: ref?.cloudPath,
                    captureDate: photo.captureDate, latitude: photo.latitude, longitude: photo.longitude,
                    placeName: photo.placeName, country: photo.country, linkKey: photo.linkKey,
                    isScreenshot: photo.isScreenshot, isFavorite: photo.isFavorite,
                    aspect: photo.aspect, people: photo.people,
                    clipVector: photo.clipVector))
            }
        }
        try? modelContext.save()
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

    /// 現存しない（削除/退避された）写真の付加情報を削除する。
    func prune(keeping refKeys: Set<String>) {
        guard let records = try? modelContext.fetch(FetchDescriptor<PhotoEnrichment>()) else { return }
        for record in records where !refKeys.contains(record.refKey) {
            modelContext.delete(record)
        }
        try? modelContext.save()
    }

    /// 付加情報済みの全写真（戦略の入力）。clipVector を**載せない**軽量版。
    /// 意味検索は `enrichmentVectorPage` でページングして埋め込みを読むため、全件 clipVector を
    /// 一度にメモリへ載せる API はあえて持たない（約138MBの一括ロード＝実機メモリ枯渇の元を断つ）。
    func allEnrichedPhotosLite() -> [EnrichedPhoto] {
        let records = (try? modelContext.fetch(FetchDescriptor<PhotoEnrichment>())) ?? []
        return records.map(\.asEnrichedPhotoLite)
    }

    /// 意味検索のバッチ化用：clipVector を持つ行を **page 単位**で `(refKey, clipVector)` として取り出す。
    /// `refKey` 昇順で安定ページング（offset/limit）。全 67k の埋め込み(約138MB)を一度に載せず、
    /// 1ページ分（例 4,000 件＝約8MB）だけをメモリに置くために使う。
    func enrichmentVectorPage(offset: Int, limit: Int) -> [(refKey: String, clipVector: Data)] {
        var descriptor = FetchDescriptor<PhotoEnrichment>(
            predicate: #Predicate { $0.clipVector != nil },
            sortBy: [SortDescriptor(\.refKey)])
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        let records = (try? modelContext.fetch(descriptor)) ?? []
        return records.compactMap { rec in
            guard let vector = rec.clipVector else { return nil }
            return (refKey: rec.refKey, clipVector: vector)
        }
    }

    func enrichmentCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<PhotoEnrichment>())) ?? 0
    }

    /// 単一 refKey の付加情報＋埋め込み試行済みフラグ（フル画像ビューの情報・状態表示用）。
    func insightRecord(refKey: String) -> (photo: EnrichedPhoto, tagged: Bool)? {
        let descriptor = FetchDescriptor<PhotoEnrichment>(predicate: #Predicate { $0.refKey == refKey })
        guard let record = try? modelContext.fetch(descriptor).first else { return nil }
        return (record.asEnrichedPhoto, record.sceneTagged)
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
        for record in records {
            record.sceneTagged = false
            record.clipVector = nil
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
    func unembeddedRefKeys(limit: Int) -> [String] {
        var descriptor = FetchDescriptor<PhotoEnrichment>(predicate: #Predicate { $0.sceneTagged == false })
        descriptor.fetchLimit = limit
        let records = (try? modelContext.fetch(descriptor)) ?? []
        return records.map(\.refKey)
    }

    /// refKey → 埋め込み を既存レコードへ反映する（取得不可でも sceneTagged を立てる＝処理済み）。
    func applyPerception(_ byRefKey: [String: PhotoPerception]) {
        for (refKey, perception) in byRefKey {
            let descriptor = FetchDescriptor<PhotoEnrichment>(predicate: #Predicate { $0.refKey == refKey })
            guard let record = try? modelContext.fetch(descriptor).first else { continue }
            record.sceneTagged = true
            if perception.clipVector != nil { record.clipVector = perception.clipVector }
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
        try? modelContext.save()
    }
}
