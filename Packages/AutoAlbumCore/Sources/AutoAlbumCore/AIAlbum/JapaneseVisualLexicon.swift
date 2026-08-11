import Foundation

/// 日本語の頻出**視覚語**と否定パターンの決定的レキシコン（純・テスト対象）。
///
/// FM（翻訳・解釈）はシミュレータ/非対応端末で失敗し得るし、小型 LLM の構造化出力は
/// 壊れ得る（実障害多数）。RelativeDateParser（日付）と同じ思想で、**よく使う視覚概念と
/// 人物否定だけは決定的に抽出**し、LLM ゼロでもタグ照合・除外・証拠ゲートが機能するようにする。
/// 網羅は目的でない（LLM が動くときは LLM が上書きする補助線）。
public enum JapaneseVisualLexicon {

    /// 日本語の視覚語 → 英語タグ語（Vision 分類・CLIP と照合できる語）。
    private static let visualWords: [(jp: [String], en: [String])] = [
        (["風景", "景色"], ["landscape", "scenery", "outdoor"]),
        (["子供", "子ども", "こども"], ["child", "children"]),
        (["赤ちゃん", "乳児"], ["baby", "infant"]),
        (["家族"], ["family"]),
        (["犬"], ["dog"]),
        (["猫"], ["cat"]),
        (["動物"], ["animal"]),
        (["鳥"], ["bird"]),
        (["海", "ビーチ", "浜辺"], ["beach", "sea", "ocean"]),
        (["山"], ["mountain"]),
        (["川"], ["river"]),
        (["空"], ["sky"]),
        (["雪"], ["snow"]),
        (["花"], ["flower"]),
        (["桜"], ["cherry blossom"]),
        (["紅葉"], ["autumn leaves", "foliage"]),
        (["夕日", "夕焼け", "日没"], ["sunset"]),
        (["夜景", "夜"], ["night"]),
        (["食べ物", "料理", "ごはん", "食事"], ["food", "meal"]),
        (["ケーキ"], ["cake"]),
        (["車", "クルマ"], ["car"]),
        (["電車", "列車"], ["train"]),
        (["飛行機"], ["airplane"]),
        (["建物", "建築"], ["building", "architecture"]),
        (["神社", "寺", "お寺"], ["shrine", "temple"]),
        (["公園"], ["park"]),
        (["花火"], ["fireworks"]),
        (["結婚式"], ["wedding"]),
        (["誕生日"], ["birthday"]),
        (["プール"], ["pool", "swimming"]),
        (["富士山"], ["mount fuji", "mountain"]),
        // --- 広い語（S9・ADR-102）。レキシコンは**日→英の翻訳だけ**を受け持ち、
        //     実在タグへの展開は語彙接地（VocabularyGrounding・重心）が行う。
        //     Caltech 計測: 「楽器の写真」がレキシコン外で 0 件だった（接地は F1 0.77 で
        //     展開できるのに、入口の翻訳が無くて届かなかった）。
        (["楽器"], ["musical instrument"]),
        (["昆虫", "虫"], ["insect"]),
        (["乗り物"], ["vehicle"]),
        (["バス"], ["bus"]),
        (["トラック"], ["truck"]),
        (["自転車"], ["bicycle"]),
        (["バイク", "オートバイ"], ["motorcycle"]),
        (["果物", "フルーツ"], ["fruit"]),
        (["ピザ"], ["pizza"]),
        (["家具"], ["furniture"]),
        // --- 動物の具体語（S10）。COCO/Vision 語彙に対応する頻出語 ---
        (["馬"], ["horse"]),
        (["牛"], ["cow"]),
        (["羊"], ["sheep"]),
        (["象", "ゾウ"], ["elephant"]),
        (["キリン"], ["giraffe"]),
        (["シマウマ"], ["zebra"]),
        (["クマ", "熊"], ["bear"]),
        // --- 日常物・食べ物・乗り物の具体語（S11・100 本クエリ評価で網羅拡充）。
        //     ⚠️ 誤爆しやすい単漢字（本→book 等・「日本」に当たる）は入れない。
        (["ボート"], ["boat"]),
        (["信号"], ["traffic light"]),
        (["ベンチ"], ["bench"]),
        (["傘", "かさ"], ["umbrella"]),
        (["ネクタイ"], ["tie"]),
        (["スーツケース"], ["suitcase"]),
        (["リュック"], ["backpack"]),
        (["ハンドバッグ", "バッグ"], ["handbag"]),
        (["フリスビー"], ["frisbee"]),
        (["スキー"], ["skis"]),
        (["スノーボード"], ["snowboard"]),
        (["ボール"], ["sports ball"]),
        (["凧", "カイト"], ["kite"]),
        (["スケートボード", "スケボー"], ["skateboard"]),
        (["サーフボード"], ["surfboard"]),
        (["テニスラケット", "ラケット"], ["tennis racket"]),
        (["ボトル", "ペットボトル"], ["bottle"]),
        (["ワイングラス", "ワイン"], ["wine glass"]),
        (["コップ", "カップ"], ["cup"]),
        (["フォーク"], ["fork"]),
        (["ナイフ"], ["knife"]),
        (["スプーン"], ["spoon"]),
        (["ボウル", "お椀"], ["bowl"]),
        (["バナナ"], ["banana"]),
        (["リンゴ", "りんご", "林檎"], ["apple"]),
        (["サンドイッチ", "サンドウィッチ"], ["sandwich"]),
        (["オレンジ", "みかん", "ミカン"], ["orange"]),
        (["ブロッコリー"], ["broccoli"]),
        (["ニンジン", "にんじん", "人参"], ["carrot"]),
        (["ホットドッグ"], ["hot dog"]),
        (["ドーナツ", "ドーナッツ"], ["donut"]),
        (["椅子", "イス", "いす"], ["chair"]),
        (["ソファ", "ソファー"], ["couch"]),
        (["ベッド"], ["bed"]),
        (["トイレ"], ["toilet"]),
        (["ダイニングテーブル", "食卓"], ["dining table"]),
        (["観葉植物", "鉢植え"], ["potted plant"]),
        (["テレビ"], ["tv"]),
        (["ノートパソコン", "パソコン"], ["laptop"]),
        (["マウス"], ["mouse"]),
        (["リモコン"], ["remote"]),
        (["キーボード"], ["keyboard"]),
        (["携帯電話", "携帯", "スマホ", "スマートフォン"], ["cell phone"]),
        (["電子レンジ", "レンジ"], ["microwave"]),
        (["オーブン"], ["oven"]),
        (["トースター"], ["toaster"]),
        (["冷蔵庫"], ["refrigerator"]),
        (["時計"], ["clock"]),
        (["花瓶"], ["vase"]),
        (["ハサミ", "はさみ"], ["scissors"]),
        (["ぬいぐるみ", "テディベア"], ["teddy bear"]),
        (["歯ブラシ"], ["toothbrush"]),
        (["ドライヤー"], ["hair drier"]),
    ]

    // MARK: - 属性語（S10・ADR-103）

    /// 「笑っている」系（→ `.smiling` 条件＝顔スキャンの hasSmile 実測）。
    private static let smileWords = ["笑顔", "笑って", "笑い", "スマイル", "ニコニコ", "微笑",
                                     "smiling", "smile", "laughing"]
    /// 「綺麗な」系（→ `.beautiful` 条件＝美的スコアの分布適応しきい値・ADR-78）。
    /// ⚠️ 「良い写真」「印象的な写真」のような**言い回し**もここへ寄せる（S11・実フィードバック）。
    ///    ユーザーが写真の良さを尋ねる言葉は多様だが、応えられる索引は美的スコア 1 本＝
    ///    どの言い回しでも同じ条件に落とすのが正直な設計（無いものに答えたふりをしない）。
    private static let beautifulWords = ["綺麗", "きれい", "キレイ", "美しい", "ベストショット",
                                         "良い写真", "いい写真", "良い感じ", "いい感じ",
                                         "素敵", "印象的", "最高の一枚",
                                         "映え", "フォトジェニック",
                                         "beautiful", "best shot", "stunning", "impressive"]

    /// 「X**だけ**の写真」＝X 以外（特に人）が写っていない意図（S12）。
    /// 語彙語の直後に だけ/のみ が続くとき true。「犬だけの写真」→ 犬＋人物除外。
    public static func hasSoloRequest(_ criteria: String) -> Bool {
        for match in matches(in: criteria) where !match.negated {
            let jp = match.jp
            if let range = criteria.range(of: jp) {
                let after = criteria[range.upperBound...]
                if after.hasPrefix("だけ") || after.hasPrefix("のみ") { return true }
            }
        }
        return false
    }

    /// 人数条件（S12）: 「2人の写真」「一人で」「集合写真」「大人数」→ (exactly, atLeast)。
    /// 実測（humanCount・上半身検出）で評価できるものだけ拾う。無ければ (nil, nil)。
    public static func peopleCountRequest(_ criteria: String) -> (exactly: Int?, atLeast: Int?) {
        // 集合写真・大人数 → 5 人以上（明確な下限は無いので慣用値）。
        if criteria.contains("集合写真") || criteria.contains("大人数") { return (nil, 5) }
        // 「N人」（半角/全角数字・一〜九）。「N人以上」は atLeast。
        let digits: [Character: Int] = ["1":1,"2":2,"3":3,"4":4,"5":5,"6":6,"7":7,"8":8,"9":9,
                                        "１":1,"２":2,"３":3,"４":4,"５":5,"６":6,"７":7,"８":8,"９":9,
                                        "一":1,"二":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
        let chars = Array(criteria)
        for (i, ch) in chars.enumerated() {
            guard let n = digits[ch], i + 1 < chars.count, chars[i + 1] == "人" else { continue }
            let rest = String(chars[(i + 2)...])
            return rest.hasPrefix("以上") ? (nil, n) : (n, nil)
        }
        if criteria.contains("ひとりで") || criteria.contains("一人で") { return (1, nil) }
        return (nil, nil)
    }

    /// 原文が笑顔条件を含むか。
    public static func hasSmileRequest(_ criteria: String) -> Bool {
        let lower = criteria.lowercased()
        return smileWords.contains { criteria.contains($0) || lower.contains($0) }
    }

    /// 原文が「綺麗な写真」条件を含むか。
    public static func hasBeautifulRequest(_ criteria: String) -> Bool {
        let lower = criteria.lowercased()
        return beautifulWords.contains { criteria.contains($0) || lower.contains($0) }
    }

    /// 人物の否定（「人が写っていない」等）のパターン。
    private static let peopleNegations = [
        "人が写っていない", "人がいない", "人物なし", "人なし", "誰もいない", "無人",
        "without people", "no people", "nobody", "without any people",
    ]

    /// 語に**後置**される否定（日本語）。「犬が写っていない」＝ 犬 ＋ が写っていない。
    private static let negationSuffixes = [
        "が写っていない", "が写ってない", "が映っていない", "が映ってない",
        "がいない", "が無い", "がない", "の無い", "のない",
        "なし", "無し", "抜き", "以外", "を除く", "を除いた", "は除く",
    ]
    /// 語に**前置**される否定（英語）。"without dogs" / "no people"。
    private static let negationPrefixes = ["without", "no ", "not ", "excluding", "except"]

    /// 語が否定されているか（原文中の位置を見て前後の否定表現を判定する）。
    ///
    /// ⚠️ ここが汎用化の要（ADR-100）。以前は「人」の否定だけを固定文字列で見ており、
    /// 「犬が写っていない写真」は**否定が丸ごと無視されて `dog` が include に立ち**、
    /// 犬の写真がそのまま返っていた（COCO 計測で precision 0.213）。語ごとに文脈を見る。
    /// 連言（と・や・、）で語をつなぐときの区切り。「犬**と**猫が写っていない」の 犬 にも
    /// 否定を届かせるために使う（ADR-100 追記）。
    private static let conjunctions = ["と", "や", "、", "・"]
    /// 連言でスキップしてよい名詞（語彙の全日本語語＋人物語）。
    private static let skippableNouns: [String] =
        visualWords.flatMap(\.jp) + ["人", "人物", "誰か"]

    /// `text` の先頭から「連言＋名詞」の並びを読み飛ばした残りを返す。
    /// 「と猫が写っていない」→「が写っていない」。連言でなければそのまま返す。
    private static func skippingConjoinedNouns(_ text: Substring) -> Substring {
        var rest = text
        // 語彙は高々数十語・連言も 2〜3 個なので素朴なループで十分。
        outer: for _ in 0..<4 {
            for conj in conjunctions where rest.hasPrefix(conj) {
                let afterConj = rest.dropFirst(conj.count)
                for noun in skippableNouns where afterConj.hasPrefix(noun) {
                    rest = afterConj.dropFirst(noun.count)
                    continue outer
                }
            }
            break
        }
        return rest
    }

    private static func isNegated(_ word: String, in criteria: String) -> Bool {
        let lower = criteria.lowercased()
        let haystacks = [criteria, lower]
        for haystack in haystacks {
            var searchStart = haystack.startIndex
            while let range = haystack.range(of: word, range: searchStart..<haystack.endIndex) {
                // 後置（日本語）: 語の直後（連言で続く名詞は読み飛ばして）に否定表現が始まるか。
                // ⚠️ 連言対応が無いと「犬**と猫**が写っていない」の 犬 に否定が届かず、
                //    dog が**肯定**に立って犬の写真を返す（実測で確認・ADR-100 追記）。
                let after = skippingConjoinedNouns(haystack[range.upperBound...]).prefix(12)
                if negationSuffixes.contains(where: { after.hasPrefix($0) }) { return true }
                // 前置（英語）: 語の直前 12 文字以内に without/no などがあるか。
                let beforeStart = haystack.index(range.lowerBound,
                                                 offsetBy: -12,
                                                 limitedBy: haystack.startIndex) ?? haystack.startIndex
                let before = haystack[beforeStart..<range.lowerBound].lowercased()
                if negationPrefixes.contains(where: { before.contains($0) }) { return true }
                searchStart = range.upperBound
            }
        }
        return false
    }

    /// CJK 統合漢字か（単漢字の複合語誤爆判定用）。
    private static func isKanji(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
    }

    /// 語彙エントリの一致（どの日本語語が・どのエントリで・否定文脈か）。
    private struct Match {
        let entryIndex: Int
        let jp: String
        let negated: Bool
    }

    /// 原文と語彙の一致を**長い語優先・占有制**で取る（S5・ADR-102）。
    ///
    /// ⚠️ 素朴な `contains` だと部分文字列が二重に当たる。実障害: 「**電車**の写真」が
    /// 電車→train に加えて **車→car にも当たり**、include=["car","train"] になって
    /// 車の写真 502 枚が混入していた（COCO 計測: train P=0.214 の正体。タグ照合は無実だった）。
    /// 長い語から先に一致させ、一致した範囲を**占有**して短い語の重複一致を禁じる
    /// （形態素解析は持ち込まない＝決定的レキシコンの範囲で最長一致だけ行う）。
    private static func matches(in criteria: String) -> [Match] {
        let lower = criteria.lowercased()
        // (語, entryIndex) を語長の降順で。同長は entry 順（安定）。
        var words: [(jp: String, entry: Int)] = []
        for (i, entry) in visualWords.enumerated() {
            for jp in entry.jp { words.append((jp: jp, entry: i)) }
        }
        words.sort { a, b in
            if a.jp.count != b.jp.count { return a.jp.count > b.jp.count }
            return a.entry < b.entry
        }
        var claimed: [Range<String.Index>] = []
        var out: [Match] = []
        var matchedEntries = Set<Int>()
        for (jp, entryIndex) in words {
            guard !matchedEntries.contains(entryIndex) else { continue }
            // 原文（かな漢字）と小文字化の両方で探す（英字混じり対応・従来と同じ）。
            for haystack in [criteria, lower] {
                var searchStart = haystack.startIndex
                var found = false
                while let range = haystack.range(of: jp, range: searchStart..<haystack.endIndex) {
                    searchStart = range.upperBound
                    // 既に長い語が占有した範囲の内側なら数えない（電車の「車」）。
                    if claimed.contains(where: { $0.overlaps(range) }) { continue }
                    // ⚠️ **単漢字は漢字に隣接していたら一致させない**（S11）。「印象的な写真」の
                    //    象→elephant、「熊本」の 熊→bear、「空港」の 空→sky のような複合語の
                    //    誤爆を防ぐ。「象の写真」（前=先頭）「白い象」（前=かな）は従来どおり当たる。
                    if jp.count == 1, isKanji(jp.unicodeScalars.first) {
                        if range.lowerBound > haystack.startIndex {
                            let before = haystack[haystack.index(before: range.lowerBound)]
                            if isKanji(before.unicodeScalars.first) { continue }
                        }
                        if range.upperBound < haystack.endIndex {
                            let after = haystack[range.upperBound]
                            if isKanji(after.unicodeScalars.first) { continue }
                        }
                    }
                    claimed.append(range)
                    out.append(Match(entryIndex: entryIndex, jp: jp,
                                     negated: isNegated(jp, in: criteria)))
                    matchedEntries.insert(entryIndex)
                    found = true
                    break
                }
                if found { break }
            }
        }
        // 出力はエントリ定義順（従来の並びを保つ＝テスト・表示の互換）。
        return out.sorted { $0.entryIndex < $1.entryIndex }
    }

    /// 原文から視覚語（英語）を決定的に抽出する。見つからなければ空。
    /// ⚠️ **否定されている語は含めない**（「犬が写っていない」で dog を肯定に立てない）。
    static func includeTerms(in criteria: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for match in matches(in: criteria) where !match.negated {
            for en in visualWords[match.entryIndex].en where seen.insert(en).inserted { out.append(en) }
        }
        return out
    }

    /// 原文から**否定された**視覚語（英語）を決定的に抽出する（ADR-100）。
    /// 「人が写っていない」も語彙経由でここに集約されるので、呼び手は人物を特別扱いしなくてよい。
    public static func excludeTerms(in criteria: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for match in matches(in: criteria) where match.negated {
            for en in visualWords[match.entryIndex].en where seen.insert(en).inserted { out.append(en) }
        }
        // 「人が写っていない」等は語彙に「人」を置かず専用パターン＋否定文脈判定で受ける。
        // ⚠️ 固定パターンだけだと**連言を跨げない**（S11）: 「人と車と自転車が写っていない」は
        //    「人が写っていない」を含まないため人物否定が落ち、人が写った写真が 1,989 枚
        //    混入していた（COCO 実測 P=0.477）。isNegated（連言スキップ内蔵）でも判定する。
        //    恋人・友人など複合語の「人」も否定文脈なら people 除外として妥当なので境界は見ない。
        if hasPeopleNegation(criteria) || isNegated("人", in: criteria)
            || isNegated("人物", in: criteria) {
            for en in ["people"] where seen.insert(en).inserted { out.append(en) }
        }
        return out
    }

    /// 入力に含まれる視覚語の（日本語, 英語代表）対。コンポーザーの**接地プレビュー**
    /// （「海 → sea」のような色付きチップ）に使う。抽出規則は `includeTerms` と同一。
    public static func groundedPairs(in criteria: String) -> [(japanese: String, english: String)] {
        matches(in: criteria).compactMap { match in
            visualWords[match.entryIndex].en.first.map { (japanese: match.jp, english: $0) }
        }
    }

    /// 英語タグ（Vision 識別子等）→ 日本語代表語。頻出タグをサジェストチップとして
    /// **日本語表示**するための逆引き（対応が無いタグは nil＝チップに出さない）。
    public static func japaneseLabel(forTag tag: String) -> String? {
        let t = tag.lowercased()
        for entry in visualWords where entry.en.contains(where: { $0 == t || t.contains($0) || $0.contains(t) }) {
            return entry.jp.first
        }
        return nil
    }

    /// 「人が写っていない」系の否定表現を含むか。
    static func hasPeopleNegation(_ criteria: String) -> Bool {
        let lower = criteria.lowercased()
        return peopleNegations.contains { criteria.contains($0) || lower.contains($0) }
    }
}
