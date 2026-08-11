import Foundation
@testable import AutoAlbumCore

/// 評価クエリと指標（純ロジック）。
///
/// 実障害が「除外条件つきクエリに、除外すべき写真が混ざる」＝**precision の問題**だったので、
/// Recall だけを見ていた既存ハーネスと違い **precision / recall / F1 を both 出す**。
/// 正解は COCO のラベルから機械的に決まる（人手の判断を入れない＝再実行で同じ数字になる）。
enum SearchEvalQueries {

    /// 1 クエリ。`include`/`exclude` は**正解の定義**（COCO クラス名）であって、
    /// パイプラインへ渡す語ではない。パイプラインには `text`（自然文）を渡す。
    struct Query {
        let id: String
        /// 分析用カテゴリ（subject / exclusion / conjunction / date / attribute / phrase / en / limitation）。
        var category: String = "subject"
        /// ユーザーが入力する自然文（日本語）。
        let text: String
        /// 夜間 FM 翻訳の代替（英語の意味文）。空なら決定的チャンネルのみで解く。
        let englishText: String
        /// 正解: これらのクラスのいずれかが写っている（空なら条件なし）。
        let include: [String]
        /// 正解: これらのクラスが 1 つも写っていない。
        let exclude: [String]
        /// 正解: 撮影年（日付複合クエリ用。nil なら日付条件なし）。
        var year: Int?
        /// 正解: クラスの最少個数（「犬が2匹」等）。nil なら 1 以上。
        var minCount: [String: Int]?
        /// 正解: 写っている人数（COCO の person 個数）。
        var personExactly: Int?
        var personAtLeast: Int?
        /// 正解: 属性の要求（S10・ADR-103）。
        var requireSmiling = false
        var requireChild = false
        var requireBeautiful = false
        /// 正解: 子供が**写っていない**（大人は可）。人物除外の粗さの定量化用。
        var requireNoChild = false
        /// 正解: この命名済み人物が写っている（「X の Y」複合クエリ用・S15）。
        var requirePerson: String?
        /// 現状の既知の限界を**定量化**するためのクエリ（マクロ平均から除外して別枠で出す）。
        /// 例: レキシコン外の語＝作成時プレビューでは立たない（夜間 FM が受け持つ）。
        var knownLimitation: String?
        /// 除外条件を含むか（証拠ゲートの対象になる＝評価の主眼）。
        var hasExclusion: Bool { !exclude.isEmpty }

        /// 正解集合（コーパスの truth から機械的に導く）。
        func groundTruth(corpus: SearchEvalCorpus.Corpus,
                         dates: [String: Date] = [:]) -> Set<String> {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            // 「綺麗」の正解 = 真値スコアの上位 20%（ADR-78 のベストショット定義と同じ）。
            let beautifulFloor = requireBeautiful
                ? PhotoQuality.adaptiveThreshold(scores: Array(corpus.truthAesthetics.values)) : 0
            var out = Set<String>()
            for (refKey, counts) in corpus.truth {
                if !include.isEmpty && !include.contains(where: { (counts[$0] ?? 0) > 0 }) { continue }
                if exclude.contains(where: { (counts[$0] ?? 0) > 0 }) { continue }
                if let minCount, minCount.contains(where: { (counts[$0.key] ?? 0) < $0.value }) { continue }
                if let personExactly, (counts["person"] ?? 0) != personExactly { continue }
                if let personAtLeast, (counts["person"] ?? 0) < personAtLeast { continue }
                if let year {
                    guard let date = dates[refKey],
                          calendar.component(.year, from: date) == year else { continue }
                }
                if let requirePerson,
                   corpus.truthPerson[requirePerson]?.contains(refKey) != true { continue }
                if requireSmiling, !corpus.truthSmiling.contains(refKey) { continue }
                if requireChild, !corpus.truthChild.contains(refKey) { continue }
                if requireNoChild, corpus.truthChild.contains(refKey) { continue }
                if requireBeautiful, (corpus.truthAesthetics[refKey] ?? -1) < beautifulFloor { continue }
                out.insert(refKey)
            }
            return out
        }
    }

    /// 評価クエリ集。実障害（人物除外）を中心に、汎用性を確かめるため
    /// **人物以外の除外**（犬・車・食べ物）と肯定のみのクエリも入れる。
    /// 汎用化が効いていれば人物以外でも同じだけ改善するはず＝点対応との区別がつく。
    /// 主要被写体（日本語 → COCO クラス）。肯定・否定・複合クエリの素材。
    /// レキシコンに対応語があることが前提（無い語は limitation 枠で測る）。
    private static let subjects: [(ja: String, en: String, cls: String)] = [
        ("犬", "dog", "dog"), ("猫", "cat", "cat"), ("馬", "horse", "horse"),
        ("象", "elephant", "elephant"), ("キリン", "giraffe", "giraffe"),
        ("シマウマ", "zebra", "zebra"), ("クマ", "bear", "bear"), ("牛", "cow", "cow"),
        ("羊", "sheep", "sheep"), ("鳥", "bird", "bird"),
        ("車", "car", "car"), ("電車", "train", "train"), ("バス", "bus", "bus"),
        ("トラック", "truck", "truck"), ("自転車", "bicycle", "bicycle"),
        ("バイク", "motorcycle", "motorcycle"), ("飛行機", "airplane", "airplane"),
        ("ボート", "boat", "boat"),
        ("ピザ", "pizza", "pizza"), ("ケーキ", "cake", "cake"), ("バナナ", "banana", "banana"),
        ("リンゴ", "apple", "apple"), ("サンドイッチ", "sandwich", "sandwich"),
        ("オレンジ", "orange", "orange"), ("ブロッコリー", "broccoli", "broccoli"),
        ("ニンジン", "carrot", "carrot"), ("ホットドッグ", "hot dog", "hot dog"),
        ("ドーナツ", "donut", "donut"),
        ("椅子", "chair", "chair"), ("ソファ", "couch", "couch"), ("ベッド", "bed", "bed"),
        ("テレビ", "tv", "tv"), ("ノートパソコン", "laptop", "laptop"),
        ("キーボード", "keyboard", "keyboard"), ("スマホ", "cell phone", "cell phone"),
        ("冷蔵庫", "refrigerator", "refrigerator"), ("時計", "clock", "clock"),
        ("花瓶", "vase", "vase"), ("ハサミ", "scissors", "scissors"),
        ("ぬいぐるみ", "teddy bear", "teddy bear"), ("傘", "umbrella", "umbrella"),
        ("ネクタイ", "tie", "tie"), ("スーツケース", "suitcase", "suitcase"),
        ("ベンチ", "bench", "bench"), ("信号", "traffic light", "traffic light"),
        ("スプーン", "spoon", "spoon"), ("ボウル", "bowl", "bowl"),
        ("サーフボード", "surfboard", "surfboard"), ("スケートボード", "skateboard", "skateboard"),
        ("凧", "kite", "kite"),
    ]

    /// 否定クエリにする被写体（頻度と多様性で選ぶ）。
    private static let exclusionSubjects: [(ja: String, cls: String)] = [
        ("犬", "dog"), ("猫", "cat"), ("車", "car"), ("バス", "bus"), ("自転車", "bicycle"),
        ("椅子", "chair"), ("スマホ", "cell phone"), ("テレビ", "tv"), ("傘", "umbrella"),
        ("ボトル", "bottle"), ("時計", "clock"), ("鳥", "bird"),
    ]

    static let all: [Query] = {
        var out: [Query] = []
        // --- subject: 「Xの写真」（50 本） ---
        for s in subjects {
            out.append(Query(id: "s-\(s.cls)", category: "subject",
                             text: "\(s.ja)の写真", englishText: s.en,
                             include: [s.cls], exclude: []))
        }
        // --- exclusion: 「Xが写っていない写真」（12 本＋人物系 3 本） ---
        for e in exclusionSubjects {
            out.append(Query(id: "x-\(e.cls)", category: "exclusion",
                             text: "\(e.ja)が写っていない写真", englishText: "",
                             include: [], exclude: [e.cls]))
        }
        out += [
            Query(id: "x-people", category: "exclusion", text: "人が写っていない写真",
                  englishText: "", include: [], exclude: ["person"]),
            Query(id: "x-people-en", category: "en", text: "photos without people",
                  englishText: "", include: [], exclude: ["person"]),
            Query(id: "x-nobody", category: "exclusion", text: "誰もいない写真",
                  englishText: "", include: [], exclude: ["person"]),
        ]
        // --- conjunction / 複合（10 本） ---
        out += [
            Query(id: "c-dog-cat", category: "conjunction", text: "犬と猫の写真",
                  englishText: "dog and cat", include: ["dog", "cat"], exclude: []),
            Query(id: "c-no-dog-cat", category: "conjunction", text: "犬と猫が写っていない写真",
                  englishText: "", include: [], exclude: ["dog", "cat"]),
            Query(id: "c-no-car-bus", category: "conjunction", text: "車やバスが写っていない写真",
                  englishText: "", include: [], exclude: ["car", "bus"]),
            Query(id: "c-cat-no-dog", category: "conjunction", text: "犬が写っていない猫の写真",
                  englishText: "cat", include: ["cat"], exclude: ["dog"]),
            Query(id: "c-dog-no-person", category: "conjunction", text: "人が写っていない犬の写真",
                  englishText: "dog", include: ["dog"], exclude: ["person"]),
            Query(id: "c-food3", category: "conjunction", text: "ピザとケーキとドーナツの写真",
                  englishText: "pizza cake donut", include: ["pizza", "cake", "donut"], exclude: []),
            Query(id: "c-no-p-c-b", category: "conjunction", text: "人と車と自転車が写っていない写真",
                  englishText: "", include: [], exclude: ["person", "car", "bicycle"]),
            Query(id: "c-bird-no-person", category: "conjunction", text: "人が写っていない鳥の写真",
                  englishText: "bird", include: ["bird"], exclude: ["person"]),
            Query(id: "c-horse-no-car", category: "conjunction", text: "車が写っていない馬の写真",
                  englishText: "horse", include: ["horse"], exclude: ["car"]),
            Query(id: "c-written", category: "conjunction", text: "犬が写っている写真",
                  englishText: "dog", include: ["dog"], exclude: []),   // 肯定の言い回し（〜が写っている）
        ]
        // --- date 複合（8 本） ---
        out += [
            Query(id: "d-dog-2024", category: "date", text: "2024年の犬の写真",
                  englishText: "dog", include: ["dog"], exclude: [], year: 2024),
            Query(id: "d-cat-2025", category: "date", text: "2025年の猫の写真",
                  englishText: "cat", include: ["cat"], exclude: [], year: 2025),
            Query(id: "d-pizza-2024", category: "date", text: "2024年のピザの写真",
                  englishText: "pizza", include: ["pizza"], exclude: [], year: 2024),
            Query(id: "d-train-2025", category: "date", text: "2025年の電車の写真",
                  englishText: "train", include: ["train"], exclude: [], year: 2025),
            Query(id: "d-nop-2025", category: "date", text: "2025年の人が写っていない写真",
                  englishText: "", include: [], exclude: ["person"], year: 2025),
            Query(id: "d-nodog-2024", category: "date", text: "2024年の犬が写っていない写真",
                  englishText: "", include: [], exclude: ["dog"], year: 2024),
            Query(id: "d-bird-2024", category: "date", text: "2024年の鳥の写真",
                  englishText: "bird", include: ["bird"], exclude: [], year: 2024),
            Query(id: "d-umb-2025", category: "date", text: "2025年の傘の写真",
                  englishText: "umbrella", include: ["umbrella"], exclude: [], year: 2025),
        ]
        // --- attribute（属性・8 本） ---
        out += [
            Query(id: "a-child", category: "attribute", text: "子供の写真",
                  englishText: "child", include: [], exclude: [], requireChild: true),
            Query(id: "a-smiling", category: "attribute", text: "笑っている写真",
                  englishText: "", include: [], exclude: [], requireSmiling: true),
            Query(id: "a-smile-child", category: "attribute", text: "笑っている子供の写真",
                  englishText: "child", include: [], exclude: [], requireSmiling: true, requireChild: true),
            Query(id: "a-beautiful", category: "attribute", text: "綺麗な写真",
                  englishText: "", include: [], exclude: [], requireBeautiful: true),
            Query(id: "a-beauty-cat", category: "attribute", text: "綺麗な猫の写真",
                  englishText: "cat", include: ["cat"], exclude: [], requireBeautiful: true),
            Query(id: "a-beauty-2024", category: "attribute", text: "2024年の綺麗な写真",
                  englishText: "", include: [], exclude: [], year: 2024, requireBeautiful: true),
            Query(id: "a-smile-2025", category: "attribute", text: "2025年の笑っている写真",
                  englishText: "", include: [], exclude: [], year: 2025, requireSmiling: true),
            Query(id: "a-beauty-nop", category: "attribute", text: "人が写っていない綺麗な写真",
                  englishText: "", include: [], exclude: ["person"], requireBeautiful: true),
        ]
        // --- phrase（言い回し・8 本）: 「良い写真」等は美的スコア条件へ寄せる設計（S11） ---
        out += [
            Query(id: "p-good", category: "phrase", text: "良い写真",
                  englishText: "", include: [], exclude: [], requireBeautiful: true),
            Query(id: "p-ii", category: "phrase", text: "いい写真だけ集めて",
                  englishText: "", include: [], exclude: [], requireBeautiful: true),
            Query(id: "p-impressive", category: "phrase", text: "印象的な写真",
                  englishText: "", include: [], exclude: [], requireBeautiful: true),
            Query(id: "p-suteki", category: "phrase", text: "素敵な写真を見たい",
                  englishText: "", include: [], exclude: [], requireBeautiful: true),
            Query(id: "p-best", category: "phrase", text: "最高の一枚",
                  englishText: "", include: [], exclude: [], requireBeautiful: true),
            Query(id: "p-insta", category: "phrase", text: "映えする食べ物の写真",
                  englishText: "food", include: ["pizza", "cake", "sandwich", "donut", "hot dog",
                                                 "banana", "apple", "orange", "broccoli", "carrot"],
                  exclude: [], requireBeautiful: true,
                  knownLimitation: "「食べ物」の展開は接地が必要（Caltech 側）＝COCO ではタグ具体語のみ"),
            Query(id: "p-nice-dog", category: "phrase", text: "良い感じの犬の写真",
                  englishText: "dog", include: ["dog"], exclude: [], requireBeautiful: true),
            Query(id: "p-smile-phrase", category: "phrase", text: "ニコニコしている写真",
                  englishText: "", include: [], exclude: [], requireSmiling: true),
        ]
        // --- en（英語直入力・5 本） ---
        out += [
            Query(id: "e-dog", category: "en", text: "dog", englishText: "dog",
                  include: ["dog"], exclude: []),
            Query(id: "e-beautiful", category: "en", text: "beautiful photos", englishText: "",
                  include: [], exclude: [], requireBeautiful: true),
            Query(id: "e-no-dogs", category: "en", text: "photos without dogs", englishText: "",
                  include: [], exclude: ["dog"]),
            Query(id: "e-smiling", category: "en", text: "smiling photos", englishText: "",
                  include: [], exclude: [], requireSmiling: true),
            Query(id: "e-pizza", category: "en", text: "pizza", englishText: "pizza",
                  include: ["pizza"], exclude: []),
        ]
        // --- 人数条件（S12・humanCount 実測） ---
        out += [
            Query(id: "n-two", category: "count", text: "2人の写真",
                  englishText: "", include: [], exclude: [], personExactly: 2),
            Query(id: "n-group", category: "count", text: "集合写真",
                  englishText: "", include: [], exclude: [], personAtLeast: 5),
            Query(id: "n-solo", category: "count", text: "一人で写っている写真",
                  englishText: "", include: [], exclude: [], personExactly: 1),
            Query(id: "n-three-up", category: "count", text: "3人以上の写真",
                  englishText: "", include: [], exclude: [], personAtLeast: 3),
        ]
        // --- 頑健性（言い回しの揺れ・正解は同じ） ---
        out += [
            Query(id: "r-sagashite", category: "robust", text: "犬の写真を探して",
                  englishText: "dog", include: ["dog"], exclude: []),
            Query(id: "r-space", category: "robust", text: "犬 写真",
                  englishText: "dog", include: ["dog"], exclude: []),
            Query(id: "r-kudasai", category: "robust", text: "猫の写真をください",
                  englishText: "cat", include: ["cat"], exclude: []),
            Query(id: "r-mitai", category: "robust", text: "電車の写真が見たい",
                  englishText: "train", include: ["train"], exclude: []),
        ]
        // --- 特異性（存在しない被写体は 0 件を返すべき） ---
        out += [
            Query(id: "z-dino", category: "specificity", text: "恐竜の写真",
                  englishText: "dinosaur", include: ["__none__"], exclude: []),
            Query(id: "z-unicorn", category: "specificity", text: "ユニコーンの写真",
                  englishText: "unicorn", include: ["__none__"], exclude: []),
            Query(id: "z-penguin", category: "specificity", text: "ペンギンの写真",
                  englishText: "penguin", include: ["__none__"], exclude: []),
        ]
        // --- limitation（未対応の言い回しの定量化・4 本） ---
        out += [
            Query(id: "l-no-child", category: "limitation", text: "子供が写っていない写真",
                  englishText: "", include: [], exclude: [], requireNoChild: true,
                  knownLimitation: "子供除外は人物除外へ丸められる（年齢証拠なし）"),
            // S12 で「だけ」対応（人物除外として解釈）→ limitation から昇格。
            Query(id: "solo-dog", category: "conjunction", text: "犬だけの写真",
                  englishText: "dog", include: ["dog"], exclude: ["person"]),
            Query(id: "solo-cat", category: "conjunction", text: "猫だけの写真",
                  englishText: "cat", include: ["cat"], exclude: ["person"]),
            Query(id: "l-two-dogs", category: "limitation", text: "犬が2匹いる写真",
                  englishText: "dog", include: ["dog"], exclude: [], minCount: ["dog": 2],
                  knownLimitation: "頭数条件は未対応（1 匹でも当たる）"),
            Query(id: "l-food-broad", category: "limitation", text: "食べ物の写真",
                  englishText: "food",
                  include: ["pizza", "cake", "sandwich", "donut", "hot dog",
                            "banana", "apple", "orange", "broccoli", "carrot"], exclude: [],
                  knownLimitation: "広い語の展開は接地が必要（COCO では測れない・Caltech 側で計測）"),
            Query(id: "l-vehicle-broad", category: "limitation", text: "乗り物の写真",
                  englishText: "vehicle",
                  include: ["car", "bus", "train", "truck", "bicycle", "motorcycle",
                            "airplane", "boat"], exclude: [],
                  knownLimitation: "同上（vehicle の接地は Caltech 側）"),
        ]
        // --- compound: 「X の Y」＝命名済み人物 × 内容/日付の AND（S15・ADR-109）---
        // 実障害「バレエの<人名>にバレエ以外が混ざる」の再発防止。FM が content に人物名を
        // 重複させても、字句チャネル（人物名一致）経由で本人の全写真が混ざらないこと。
        // englishText は FM 翻訳を模して**わざと人物名入り**にする（実運用と同じ形で解けること）。
        out += [
            Query(id: "p-taro-dog", category: "compound", text: "太郎の犬の写真",
                  englishText: "dog photos of Taro Yamada",
                  include: ["dog"], exclude: [], requirePerson: "山田太郎"),
            Query(id: "p-taro-cake", category: "compound", text: "山田太郎のケーキの写真",
                  englishText: "cake photos of Taro Yamada",
                  include: ["cake"], exclude: [], requirePerson: "山田太郎"),
            Query(id: "p-hanako-bicycle", category: "compound", text: "花子の自転車の写真",
                  englishText: "bicycle photos of Hanako Suzuki",
                  include: ["bicycle"], exclude: [], requirePerson: "鈴木花子"),
            Query(id: "p-hanako-cat", category: "compound", text: "花子と猫の写真",
                  englishText: "photos of Hanako with a cat",
                  include: ["cat"], exclude: [], requirePerson: "鈴木花子"),
            // 人物のみ（内容語なし）: ハード絞り込み結果＝本人の全写真が返ること
            // （英訳文の CLIP band で欠けない＝ADR-109 の base 返し）。
            Query(id: "p-taro-only", category: "compound", text: "太郎の写真",
                  englishText: "photos of Taro Yamada",
                  include: [], exclude: [], requirePerson: "山田太郎"),
            // 人物 × 日付（ハード×ハードの複合）。
            Query(id: "p-hanako-2024", category: "compound", text: "2024年の花子の写真",
                  englishText: "photos of Hanako Suzuki from 2024",
                  include: [], exclude: [], year: 2024, requirePerson: "鈴木花子"),
            // 人物 × 除外（「太郎の、犬が写っていない写真」）＝ AND ＋証拠ゲートの複合。
            Query(id: "p-taro-no-dog", category: "compound", text: "犬が写っていない太郎の写真",
                  englishText: "",
                  include: [], exclude: ["dog"], requirePerson: "山田太郎"),
        ]
        return out
    }()

    // MARK: - 指標

    struct Score {
        let queryID: String
        let hasExclusion: Bool
        let truePositives: Int
        let retrieved: Int
        let relevant: Int

        /// ⚠️ 正解が 0 件のクエリ（存在しない被写体＝特異性の検査）は「0 件を返す」のが正解。
        var precision: Double {
            if relevant == 0 { return retrieved == 0 ? 1 : 0 }
            return retrieved == 0 ? 0 : Double(truePositives) / Double(retrieved)
        }
        var recall: Double {
            if relevant == 0 { return retrieved == 0 ? 1 : 0 }
            return Double(truePositives) / Double(relevant)
        }
        var f1: Double {
            let (p, r) = (precision, recall)
            return (p + r) == 0 ? 0 : 2 * p * r / (p + r)
        }
        /// 誤って混ざった件数（実障害の直接指標）。
        var falsePositives: Int { retrieved - truePositives }
    }

    static func score(queryID: String, hasExclusion: Bool,
                      retrieved: Set<String>, relevant: Set<String>) -> Score {
        Score(queryID: queryID, hasExclusion: hasExclusion,
              truePositives: retrieved.intersection(relevant).count,
              retrieved: retrieved.count, relevant: relevant.count)
    }

    /// マクロ平均（クエリごとに等重み）。件数の多いクエリに引きずられないようにする。
    static func macro(_ scores: [Score]) -> (precision: Double, recall: Double, f1: Double) {
        guard !scores.isEmpty else { return (0, 0, 0) }
        let n = Double(scores.count)
        return (scores.reduce(0) { $0 + $1.precision } / n,
                scores.reduce(0) { $0 + $1.recall } / n,
                scores.reduce(0) { $0 + $1.f1 } / n)
    }
}
