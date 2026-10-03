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
    /// 旧 VLM キャプション（英語）。機能は廃止（ADR-108）だが、**プロパティを消すと TagsV1
    /// コンテナのスキーマ不整合で全シーンタグ（数万件・数週間分）を失う**ため、フィールドだけ残す。
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

/// タグ・キャプションの @ModelActor ストア。⚠️ 本番はオフメイン生成（コンテナを開く I/O をメインから外す。@ModelActor は init した
/// スレッドで実行される・事例参照）。
@ModelActor
actor TagStore {
    /// ⚠️ **専用のシリアルキューで走らせる**（`ModelStoreExecutor` に理由を詳述）。
    /// SwiftData の既定 executor はジョブを**呼び出し元のスレッド**で実行するため、これが無いと
    /// MainActor からの `await store.…` が**メインスレッドで**走る（実測の前面ハングの真因）。
    private nonisolated let executorQueue = ModelStoreExecutor.serialQueue(label: "com.mosaicphotos.store.tags")
    nonisolated var unownedExecutor: UnownedSerialExecutor { executorQueue.asUnownedSerialExecutor() }

    /// テスト用: このストアのジョブがメインスレッドで走っていないかを確かめる
    /// （`unownedExecutor` の回帰検証。`ModelActorExecutorTests` から呼ぶ）。
    func runsOnMainThreadForTesting() -> Bool { Thread.isMainThread }

    /// テスト用: 台帳の**全件読み出し**（`allTags` / `allHumanCounts` / `allOcrTexts` /
    /// `allAesthetics`）が何回走ったか。規模退行テスト（ADR-119）の土台。
    ///
    /// ⚠️ 検証するのは**時間ではなく回数**。全件読み出しは写真数に比例するので、
    /// 「アルバム数を増やしても回数が増えないこと」が見たい性質そのものになる。
    /// インスタンスごとに数える（グローバルのカウンタだと、並行して走る別の Suite の
    /// 読み出しが混ざる）。
    private(set) var fullLedgerReadsForTesting = 0

    private static let log = LogChannel(subsystem: "com.mosaicphotos.AutoAlbum", label: "Tags")

    /// 現行のタグ付け版。v2: OCR・動物・人物数・美的スコア・アセット種別タグを追加。
    /// v3: シーンタグを precision 0.75・最大 25 個へ拡大（検索インデックスは広めに・
    /// 表示は上位 10 のまま）＋ OCR の信頼度足切り。版上げで既存写真も夜間に再タグされる。
    static let currentVersion = 3

    static func makeContainer(isStoredInMemoryOnly: Bool = false) -> ModelContainer {
        let schema = Schema([PhotoTagRecord.self])
        // ⚠️ テスト用の容器は **`makeInMemoryModelContainer` だけ**が作る（MosaicSupport）。
        if isStoredInMemoryOnly { return makeInMemoryModelContainer(for: schema) }
        return resilientModelContainer(name: "TagsV1", schema: schema) { Self.log.error($0) }
    }

    init(isStoredInMemoryOnly: Bool = false) {
        self.init(modelContainer: Self.makeContainer(isStoredInMemoryOnly: isStoredInMemoryOnly))
    }

    // MARK: - タグ付け進捗


    /// **読み取り専用の全件走査**を、使い捨ての `ModelContext` でページ分けして行う。
    ///
    /// ⚠️ SwiftData の長生きコンテキストは**実体化した行を登録し続ける**（ADR-224 の実測）。
    /// タグ台帳は 8 万行 ×（タグ配列・OCR 文字列）なので、1 回の全件 fetch が数十 MB の常駐に
    /// なり、**そのまま解放されない**。ページごとに使い捨てのコンテキストで読み、値へ写したら
    /// 捨てる（`AutoAlbumStore` の埋め込みページングと同じ手）。
    /// ⚠️ **書き込みには使わない**（ここで取った `@Model` を本体のコンテキストへ渡さないこと）。
    private func forEachRecordPage(_ body: ([PhotoTagRecord]) -> Void) {
        var cursor: String?
        while true {
            let ctx = ModelContext(modelContainer)
            var descriptor: FetchDescriptor<PhotoTagRecord>
            if let cursor {
                descriptor = FetchDescriptor<PhotoTagRecord>(
                    predicate: #Predicate { $0.refKey > cursor },
                    sortBy: [SortDescriptor(\.refKey, comparator: .lexical)])
            } else {
                descriptor = FetchDescriptor<PhotoTagRecord>(
                    sortBy: [SortDescriptor(\.refKey, comparator: .lexical)])
            }
            descriptor.fetchLimit = Self.readPageSize
            guard let page = try? ctx.fetch(descriptor), !page.isEmpty else { return }
            body(page)
            cursor = page.last?.refKey
            if page.count < Self.readPageSize { return }
        }
    }

    /// 読み取りのページの大きさ（実体化した行をページごとに手放す）。
    static let readPageSize = 5_000

    /// タグ付け済み（現行版）の refKey 集合。
    /// ⚠️⚠️ **`propertiesToFetch` では実体化は減らない**（ADR-236/246・実機ログ diagnostics-102）。
    /// ここには「8 万件のタグ配列を実体化しない（射影）」というコメントが付いていたが、
    /// **それは誤り**——あの指定はヒントで、`PersistentModel` は結局まるごと実体化され、
    /// しかも**このストアのコンテキストが登録し続ける**。実機では `tags` の手番で
    /// `enrichedRefKeysNewestFirst()` とここを続けて呼び、**1 ステップで +341MB**
    /// （430MB → 771MB）積んでから「やることが無い」と分かって畳んでいた。
    /// 背面ではメモリ圧迫で 11 回落とされていた。
    /// → **使い捨てコンテキストのページ読み**（`forEachRecordPage`）で値だけ集める。
    func taggedRefKeys() -> Set<String> {
        let v = Self.currentVersion
        var out = Set<String>()
        forEachRecordPage { page in
            for record in page where record.version >= v { out.insert(record.refKey) }
        }
        return out
    }

    /// **現行版でタグ付け済みの件数**（安い・`fetchCount`）。
    ///
    /// ⚠️ 「やることがあるか」を**全件を実体化せずに**判断するための数（ADR-247）。
    /// `taggedCount()` は版を問わないので、進捗の印には使えない（旧版の記録が混ざる）。
    func taggedCountCurrentVersion() -> Int {
        let v = Self.currentVersion
        return (try? modelContext.fetchCount(FetchDescriptor<PhotoTagRecord>(
            predicate: #Predicate { $0.version >= v }))) ?? 0
    }

    /// 台帳の記録数（診断用）。⚠️ 進捗の分子に使わない——削除・移動した写真の記録や旧版の記録が
    /// 残るので、台帳（PhotoEnrichment）の件数を分母にすると 100% を超える（実機: 86,821 枚中 88,184）。
    func taggedCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<PhotoTagRecord>())) ?? 0
    }

    /// 指定した写真（台帳の refKey）のうち、現行版でタグ付け済みの枚数（進捗の分子）。
    /// 分母と同じ列挙から数えるので、削除済みの記録・旧版の記録は入らない。
    func taggedCount(among refKeys: [String]) -> Int {
        let done = taggedRefKeys()
        return refKeys.reduce(0) { $0 + (done.contains($1) ? 1 : 0) }
    }

    /// タグの頻度上位（識別子・降順）。AI アルバム作成のサジェストチップ
    /// （「よく写るもの」＝頻出タグ∩レキシコンの日本語表示）に使う。
    func topTags(limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        forEachRecordPage { records in
            for record in records {
                for tag in record.tags { counts[tag, default: 0] += 1 }
            }
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    /// バッチ記録（save は 1 回）。既存レコードは更新（版を上げて再タグした場合も上書き）。
    /// - Returns: **永続化できたか**。取り込み側は成功したときだけ「取り込み済み」を記録する
    ///   （握り潰すと、欠けたまま同じ解析データを二度と取りに行かない・レビュー指摘）。
    @discardableResult
    func recordTags(_ batch: [(refKey: String, info: PhotoSenseInfo)]) -> Bool {
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
        do {
            try modelContext.save()
            return true
        } catch {
            Self.log.error("recordTags: save failed — \(error)")
            modelContext.rollback()
            return false
        }
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
        var freq: [String: Int] = [:]
        forEachRecordPage { records in
            for r in records {
                for tag in r.tags { freq[tag.lowercased(), default: 0] += 1 }
            }
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
        fullLedgerReadsForTesting += 1
        var out: [String: [String]] = [:]
        forEachRecordPage { records in
            for r in records where !r.tags.isEmpty { out[r.refKey] = r.tags }
        }
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
        fullLedgerReadsForTesting += 1
        var out: [String: Int] = [:]
        forEachRecordPage { records in
            for r in records {
                if let count = r.humanCount { out[r.refKey] = count }
            }
        }
        return out
    }

    /// 全 OCR 台帳（refKey → 写真内テキスト・非空のみ）。字句検索（LexicalSearch）用。
    func allOcrTexts() -> [String: String] {
        fullLedgerReadsForTesting += 1
        var out: [String: String] = [:]
        forEachRecordPage { records in
            for r in records { if let t = r.ocrText, !t.isEmpty { out[r.refKey] = t } }
        }
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
        fullLedgerReadsForTesting += 1
        var d = FetchDescriptor<PhotoTagRecord>(predicate: #Predicate { $0.aesthetic != nil })
        d.propertiesToFetch = [\.refKey, \.aesthetic]
        let records = (try? modelContext.fetch(d)) ?? []
        var out: [String: Double] = [:]
        out.reserveCapacity(records.count)
        for r in records { if let a = r.aesthetic { out[r.refKey] = a } }
        return out
    }

    func reset() {
        try? modelContext.delete(model: PhotoTagRecord.self)
        try? modelContext.save()
    }
}

/// 「シーンタグ付けを走らせてよいか」の純ロジック（ADR-247）。
///
/// ⚠️⚠️ 実機ログ diagnostics-102 で、`tags` の手番が**毎回**
/// `enrichedRefKeysNewestFirst()`（8.6 万行）＋ `taggedRefKeys()`（8.6 万行）＋ 8.6 万件の
/// 安定ソートを**先に**やってから、`tags: start` も出ないまま「やることが無い」と分かって
/// 畳んでいた——**1 ステップで +341MB**。背面ではメモリ圧迫で 11 回落とされていた。
///
/// ⚠️ コードのコメントは既に「**やる気が無いときに準備だけしていた**」と書いてあり、
/// *ゲートの順番*（譲りを先に見る）は直してあったが、*仕事が無い場合*は直っていなかった。
/// 「入ってよいか」と「やることがあるか」は別の問いで、後者は**安い数**で答えられる。
///
/// 答えが変わり得る入力は 2 つだけ:
/// 1. 取り込み済み写真の数（増えればタグ付けすべき写真が増える）
/// 2. 現行版でタグ付け済みの数（進めば残りが減る）
/// どちらも動いていなければ、前回「やることが無い」と分かった結論は変わらない。
public enum TagWorkGate {

    /// 前回と同じ入力なら、重い準備ごと飛ばしてよい。
    /// - Parameters:
    ///   - enriched: いまの取り込み済み写真の数。
    ///   - tagged: いまの現行版タグ付け済みの数。
    ///   - lastEnriched: **前回「やることが無い」と分かったとき**の `enriched`（nil＝未記録）。
    ///   - lastTagged: 同じときの `tagged`。
    public static func canSkip(enriched: Int, tagged: Int,
                               lastEnriched: Int?, lastTagged: Int?) -> Bool {
        // ⚠️ 未記録なら必ず走る（nil を「同じ」と読むと初回から飛ばしてしまう）。
        guard let lastEnriched, let lastTagged else { return false }
        return enriched == lastEnriched && tagged == lastTagged
    }

    /// **札を立ててよいか**（＝「やることが無かった」と覚えてよいか）。
    ///
    /// ⚠️⚠️ ゲートで本当に危ないのはこちら側。`canSkip` を間違えれば「無駄に +341MB 払う」だけだが、
    /// **札を立てる条件を間違えると、残りが永久にタグ付けされない**（次からずっと飛ばす）。
    /// それなのにこの判断は呼び出し側にインラインで書かれていて、テストが無かった
    /// ——台帳（gates.md）の宿題に挙がっていた分（ADR-253）。
    /// - Parameter remaining: `tagUnprocessed` の戻り。
    ///   - 0: 本当に終わった → 立ててよい
    ///   - 0 より大: **上限で打ち切った** → 立てない（残りが永久に残る）
    ///   - nil: **走れなかった**（provider 無し・二重起動）→ 立てない。⚠️ 0 と混ぜない
    public static func shouldRecord(remaining: Int?) -> Bool { remaining == 0 }
}
