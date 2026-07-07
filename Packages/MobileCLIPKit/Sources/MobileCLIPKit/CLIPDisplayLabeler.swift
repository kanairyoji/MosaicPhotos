import AutoAlbumCore
import Foundation
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
    private let maxTags = 6
    private let margin: Float = 0.04   // 最上位類似度からこの差以内のものを採用

    /// 概念埋め込み（約300語の text encode）を事前構築する（夜間パイプラインの先頭で呼ばれる）。
    /// これにより初回に写真を開いた瞬間の数秒の構築コストがフォアグラウンドから消える。
    public nonisolated func prewarm() async {
        _ = ensureEmbeddings()
    }

    /// ⚠️ nonisolated：概念埋め込みの一括構築（~300 text encode）をメインスレッドで走らせない。
    public nonisolated func labels(forEmbedding clipVector: Data) async -> [String] {
        guard let image = ClipMath.decode(clipVector), !image.isEmpty,
              let embeddings = ensureEmbeddings(), !embeddings.isEmpty else { return [] }
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
    nonisolated private func ensureEmbeddings() -> [(tag: String, vector: [Float])]? {
        lock.lock(); defer { lock.unlock() }
        if let conceptEmbeddings { return conceptEmbeddings }
        guard MobileCLIPRuntime.shared.isAvailable, let tokenizer = CLIPTokenizer.shared else { return nil }
        let started = Date()
        var built: [(tag: String, vector: [Float])] = []
        built.reserveCapacity(Self.concepts.count)
        for concept in Self.concepts {
            let tokens = tokenizer.encode("a photo of \(concept)")
            if let vector = MobileCLIPRuntime.shared.encodeText(tokens), !vector.isEmpty {
                built.append((tag: concept, vector: vector))
            }
        }
        let secs = String(format: "%.1f", Date().timeIntervalSince(started))
        Self.log.notice("CLIPDisplayLabeler: built \(built.count, privacy: .public) concept embeddings in \(secs, privacy: .public)s")
        conceptEmbeddings = built
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
