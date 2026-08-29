import AutoAlbumCore
import Foundation
import MosaicSupport
import os

/// フル画像ビューの**表示専用**タグを、保存済み CLIP 画像埋め込みに対する CLIP ゼロショットで作る。
///
/// 検索は語彙ゼロのオープン語彙 CLIP のまま。本ラベラは「この写真に何が写っているか」を読める
/// 言葉で**表示する**ためだけに、約300語の一般英語キーワード集合とのコサイン類似で上位概念を選ぶ。
/// 画像は再読み込みせず、既に保存済みの `clipVector` を使うので軽い。
public final class CLIPDisplayLabeler: LabelProvider, @unchecked Sendable {
    public init() {}

    private static let log = Logger(subsystem: "com.mosaicphotos.AutoAlbum", category: "labeler")
    private let lock = NSLock()
    private var conceptEmbeddings: [(tag: String, vector: [Float])]?
    /// 構築中の Task（後続の呼び出しはこれに合流する＝約300回の text encode を二重に走らせない）。
    private var buildTask: Task<[(tag: String, vector: [Float])]?, Never>?
    private let maxTags = 6
    /// ゲート確認の間隔（語数）。1 語ごとに MainActor へホップすると往復が 300 回になるので間引く。
    private static let gateCheckStride = 8
    private let margin: Float = 0.04   // 最上位類似度からこの差以内のものを採用

    /// 概念埋め込み（約300語の text encode）を事前構築する（夜間パイプラインの先頭で呼ばれる）。
    /// これにより初回に写真を開いた瞬間の数秒の構築コストがフォアグラウンドから消える。
    ///
    /// ⚠️ **始める直前にもう一度ゲートを見る**（実機 diagnostics-65/66）。この Task が作られるのは
    /// ゲートが開いた瞬間だが、実際に走り出すのは（プロセス中断を挟んで）ずっと後になり得る。
    /// 最初の `encodeText` が CLIP テキストタワーのロード（実測 12.9 秒・約 120MB）を起こし、
    /// **ロードは中断できない**ので、起動の一括ロードや前面復帰と重なると footprint が跳ねる
    /// （569MB まで伸び、しかも直後に `cancelPrewarm` で捨てられていた＝完全な無駄）。
    /// 判定は `heavyShouldPause()` に集約されている（`HeavyLoad` の札も含む）。
    public nonisolated func prewarm() async {
        if await MainActor.run(body: { BackgroundYield.heavyShouldPause() }) {
            Diagnostics.mark("labeler: prewarm deferred — heavy work paused before model load")
            return
        }
        _ = await ensureEmbeddings()
    }

    /// 進行中の構築を中断する（フォアグラウンド復帰・ADR-95 追記）。
    ///
    /// ⚠️ `ensureEmbeddings()` は二重構築を防ぐため**共有の `buildTask` に合流**する作りなので、
    /// 呼び出し元（`prewarmTask`）を cancel しても構築本体には伝わらない。ここで共有 Task を
    /// 直接 cancel する。中断すると `conceptEmbeddings` は nil のままなので `isReady` は false、
    /// フル画像 insight は CLIP ラベルを飛ばして Vision タグだけで即返る（表示は壊れない）。
    public nonisolated func cancelPrewarm() {
        lock.lock()
        let task = buildTask
        buildTask = nil
        lock.unlock()
        task?.cancel()
    }

    /// 概念埋め込みが構築済みか（構築を発生させない即時判定）。未構築のとき insight は CLIP ラベルを
    /// スキップして Vision タグだけで即返す（初回の CLIP テキストタワー〜数十秒ロードで固まらないように）。
    public var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return conceptEmbeddings != nil
    }

    /// ⚠️ nonisolated：概念埋め込みの一括構築（~300 text encode）をメインスレッドで走らせない。
    public nonisolated func labels(forEmbedding clipVector: Data) async -> [String] {
        guard let image = ClipMath.decode(clipVector), !image.isEmpty,
              let embeddings = await ensureEmbeddings(), !embeddings.isEmpty else { return [] }
        var scored = embeddings.map { (tag: $0.tag, score: ClipMath.cosine(image, $0.vector)) }
        scored.sort { $0.score > $1.score }
        guard let top = scored.first?.score else { return [] }
        var out: [String] = []
        for item in scored {
            guard item.score >= top - margin, out.count < maxTags else { break }
            out.append(item.tag)
        }
        return out
    }

    /// 概念テキスト埋め込みを遅延構築（セッション内キャッシュ）。
    /// 約300回の `encodeText` はそれぞれ ANE 直列化ゲートを取り**1 語ずつ**譲る。まとめてゲートを
    /// 握り続けると、その数秒〜十数秒のあいだ顔スキャン・タグ付けが完全に止まるため。
    /// ロックは状態の読み書きだけに使い、await を跨いで保持しない（構築中は `buildTask` に合流させる）。
    nonisolated private func ensureEmbeddings() async -> [(tag: String, vector: [Float])]? {
        let task: Task<[(tag: String, vector: [Float])]?, Never>
        lock.lock()
        if let conceptEmbeddings { lock.unlock(); return conceptEmbeddings }
        if let buildTask {
            task = buildTask
        } else {
            task = Task { await Self.buildEmbeddings() }
            buildTask = task
        }
        lock.unlock()

        let built = await task.value
        lock.lock()
        if let built { conceptEmbeddings = built }
        buildTask = nil
        lock.unlock()
        return built
    }

    private static func buildEmbeddings() async -> [(tag: String, vector: [Float])]? {
        guard MobileCLIPRuntime.shared.isAvailable, let tokenizer = CLIPTokenizer.shared else { return nil }
        let started = Date()
        var built: [(tag: String, vector: [Float])] = []
        built.reserveCapacity(concepts.count)
        for concept in concepts {
            // ⚠️ 1 語ごとに中断を見る（ADR-95 追記）。以前は中断点が無く、いったん始まると
            //    約300語の encode ＋ CLIP テキストタワーのロード（実機で 15.5 秒）が走り切り、
            //    その間 ANE ゲートを占有していた。前面復帰時に手放せることが重要。
            //    途中結果は**確定させない**（nil を返す）＝ isReady は false のまま次の機会に作り直す。
            if Task.isCancelled {
                Diagnostics.mark("labeler: prewarm cancelled at \(built.count)/\(concepts.count)")
                return nil
            }
            // ⚠️ ゲートも 1 語ごとに見る（キャンセルだけでは足りない）。前面復帰や起動の一括ロードが
            // 始まったら、`cancelPrewarm` が届かなくても自分から降りる。
            if built.count % Self.gateCheckStride == 0,
               await MainActor.run(body: { BackgroundYield.heavyShouldPause() }) {
                Diagnostics.mark("labeler: prewarm yielded at \(built.count)/\(concepts.count)")
                return nil
            }
            let tokens = tokenizer.encode("a photo of \(concept)")
            if let vector = await MobileCLIPRuntime.shared.encodeText(tokens), !vector.isEmpty {
                built.append((tag: concept, vector: vector))
            }
        }
        let ms = Date().timeIntervalSince(started) * 1000
        PerfTrace.logSpan("labeler.prewarm", ms: ms)
        let secs = String(format: "%.1f", ms / 1000)
        log.notice("CLIPDisplayLabeler: built \(built.count, privacy: .public) concept embeddings in \(secs, privacy: .public)s")
        return built
    }

    // MARK: - 表示用キーワード集合（約300語・具体的な被写体/シーン/活動/物）

    static let concepts: [String] = [
        // 人・社会
        "portrait", "selfie", "group of people", "baby", "toddler", "child", "children", "teenager",
        "family", "couple", "friends", "crowd", "wedding", "party", "birthday party", "graduation",
        "concert", "festival", "parade", "business meeting", "team", "audience", "performer", "dancer",
        // 動物
        "dog", "puppy", "cat", "kitten", "bird", "parrot", "owl", "eagle", "duck", "swan", "chicken",
        "fish", "shark", "dolphin", "whale", "turtle", "frog", "snake", "lizard", "horse", "cow",
        "sheep", "goat", "pig", "deer", "rabbit", "squirrel", "fox", "bear", "lion", "tiger",
        "elephant", "giraffe", "monkey", "panda", "kangaroo", "insect", "butterfly", "bee", "spider",
        "jellyfish", "crab", "zoo", "aquarium",
        // 食べ物・飲み物
        "food", "breakfast", "lunch", "dinner", "dessert", "cake", "cupcake", "cookie", "chocolate",
        "ice cream", "candy", "bread", "sandwich", "pizza", "burger", "fries", "hot dog", "pasta",
        "noodles", "ramen", "sushi", "rice bowl", "salad", "soup", "steak", "barbecue", "seafood",
        "fruit", "vegetables", "coffee", "tea", "juice", "cocktail", "beer", "wine",
        // 自然・風景
        "mountain", "hill", "valley", "cliff", "beach", "sea", "ocean", "wave", "lake", "pond",
        "river", "waterfall", "forest", "jungle", "tree", "palm tree", "flower", "rose", "sunflower",
        "garden", "grass field", "meadow", "farm", "desert", "sand dune", "canyon", "cave", "volcano",
        "glacier", "iceberg", "island", "sunset", "sunrise", "sky", "clouds", "rainbow", "lightning",
        "storm", "snow", "ice", "autumn leaves", "cherry blossom", "starry sky", "aurora", "fog",
        // 都市・建築・屋内
        "city skyline", "downtown", "street", "alley", "road", "highway", "bridge", "tunnel",
        "skyscraper", "building", "house", "apartment", "cabin", "cottage", "castle", "palace",
        "temple", "shrine", "church", "mosque", "tower", "lighthouse", "statue", "monument",
        "fountain", "plaza", "market", "shop", "shopping mall", "supermarket", "restaurant interior",
        "cafe interior", "bar", "kitchen", "bedroom", "bathroom", "living room", "office",
        "classroom", "library", "museum", "gym", "hospital", "factory", "warehouse",
        "construction site", "parking lot", "playground", "stadium", "amusement park",
        "swimming pool", "hotel lobby", "airport terminal", "train station", "subway station",
        // 乗り物
        "car", "sports car", "truck", "van", "bus", "taxi", "train", "subway", "tram", "bicycle",
        "motorcycle", "scooter", "airplane", "helicopter", "hot air balloon", "boat", "sailboat",
        "yacht", "ship", "ferry", "canoe", "traffic jam",
        // 活動・イベント
        "hiking", "camping", "fishing", "skiing", "snowboarding", "surfing", "swimming", "diving",
        "running", "cycling", "rock climbing", "yoga", "gym workout", "soccer", "basketball",
        "baseball", "tennis", "golf", "skateboarding", "dancing", "singing", "cooking", "baking",
        "gardening", "painting", "drawing", "reading", "shopping", "fireworks", "christmas",
        "halloween", "picnic", "road trip",
        // 物
        "book", "newspaper", "magazine", "laptop", "computer", "smartphone", "tablet", "camera",
        "television", "headphones", "clock", "wristwatch", "lamp", "candle", "mirror", "painting on wall",
        "poster", "sign", "flag", "balloon", "gift box", "backpack", "suitcase", "umbrella", "shoes",
        "hat", "glasses", "jewelry", "ring", "necklace", "toy", "teddy bear", "ball", "guitar",
        "piano", "drum", "microphone", "potted plant", "bouquet of flowers", "vase", "map", "ticket",
        "document", "whiteboard", "chart",
        // 時間帯・天候・撮り方
        "night scene", "neon lights", "silhouette", "reflection", "rainy day", "snowy day",
        "foggy morning", "aerial view", "underwater", "close-up", "black and white photo",
    ]
}
