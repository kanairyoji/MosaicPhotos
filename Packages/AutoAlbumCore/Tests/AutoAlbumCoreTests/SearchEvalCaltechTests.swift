import Foundation
import Testing
@testable import AutoAlbumCore

/// **接地込み**のエンドツーエンド検索評価（Caltech-101・手動実行専用）。
///
/// COCO ハーネス（`SearchEvalTests`）は解釈→照合→証拠ゲートを測るが、**語彙接地が入らない**
/// （COCO の画像が取れず重心を作れないため）。ここは Caltech の実重心（`centroids.json`）を使い、
/// 「動物の写真」のような**広い語のクエリ**を本番と同一の経路
/// （プレビュー解釈 → `VocabularyGrounding.apply` → タグ照合 → 証拠ゲート）で測る。
///
/// 実行:
/// ```
/// scripts/fetch_search_eval_datasets.sh
/// source .mobileclip_build/venv/bin/activate && python scripts/gen_centroid_fixture.py
/// cd Packages/AutoAlbumCore && swift test --filter SearchEvalCaltech
/// ```
@Suite("SearchEvalCaltech (接地込みエンドツーエンド)")
struct SearchEvalCaltechTests {

    // MARK: - フィクスチャ（centroids.json）

    private struct Fixture: Decodable {
        let vocabulary: [String]
        let textImage: [String: [Double]]
        let centroidMutual: [[Double]]?
        let imagesPerClass: [String: Int]
    }

    private static var fixtureURL: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent(".search_eval/centroids.json")
    }

    private static func coherenceClosure(_ m: [[Double]]?) -> (([Int]) -> Double)? {
        guard let m, !m.isEmpty else { return nil }
        var background: [Double] = []
        for a in 0..<m.count { for b in (a + 1)..<m.count { background.append(m[a][b]) } }
        let mean = background.reduce(0, +) / Double(background.count)
        let sd = (background.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(background.count)).squareRoot()
        guard sd > 0 else { return nil }
        return { indices in
            guard indices.count >= 2 else { return 0 }
            var total = 0.0; var count = 0
            for i in 0..<indices.count {
                for j in (i + 1)..<indices.count { total += m[indices[i]][indices[j]]; count += 1 }
            }
            return (total / Double(count) - mean) / sd
        }
    }

    // MARK: - 正解（人手・保守的。実装側には対応表を持たせない）

    private static let animals: Set<String> = [
        "emu", "flamingo", "flamingo head", "okapi", "llama", "cougar body", "cougar face",
        "beaver", "platypus", "wild cat", "hedgehog", "crocodile", "crocodile head", "gerenuk",
        "elephant", "kangaroo", "dolphin", "ibis", "sea horse", "rhino", "panda", "octopus",
        "dalmatian", "bass", "pigeon", "rooster", "butterfly", "ant", "dragonfly", "mayfly",
        "crab", "lobster", "crayfish", "scorpion", "leopards", "hawksbill", "brontosaurus",
        "stegosaurus", "starfish", "tick", "snail", "sea urchin",
    ]
    private static let flowers: Set<String> = ["lotus", "water lilly", "sunflower"]
    private static let birds: Set<String> = ["emu", "flamingo", "flamingo head", "ibis", "pigeon", "rooster"]
    private static let foods: Set<String> = ["pizza", "strawberry", "lobster", "crab"]
    private static let instruments: Set<String> = ["accordion", "electric guitar", "euphonium",
                                                   "grand piano", "mandolin", "saxophone", "gramophone"]
    /// ⚠️ 循環の注意: この 4 クラスは接地の出力とほぼ同じ（Caltech に風景クラスが少ない）。
    /// 「風景らしいクラス」の独立な人手判断としては妥当だが、他クエリより弱い正解であることを台帳に明記。
    private static let scenery: Set<String> = ["pagoda", "minaret", "pyramid", "joshua tree"]

    private struct Query {
        let id: String
        let text: String
        let truth: (String) -> Bool          // クラス名 → 正解か
        var hasExclusion = false
        var knownLimitation: String?
    }

    private static let queries: [Query] = [
        // --- 広い語の肯定（接地の主戦場） ---
        Query(id: "animal", text: "動物の写真", truth: { animals.contains($0) }),
        Query(id: "flower", text: "花の写真", truth: { flowers.contains($0) }),
        Query(id: "bird", text: "鳥の写真", truth: { birds.contains($0) }),
        Query(id: "food", text: "食べ物の写真", truth: { foods.contains($0) }),
        Query(id: "scenery", text: "風景の写真", truth: { scenery.contains($0) }),
        // --- ASCII 直入力（英語ユーザー・完全一致の経路） ---
        Query(id: "pizza-en", text: "pizza", truth: { $0 == "pizza" }),
        Query(id: "laptop-en", text: "laptop", truth: { $0 == "laptop" }),
        // --- 広い語の否定（接地された除外の展開） ---
        Query(id: "no-animal", text: "動物が写っていない写真",
              truth: { !animals.contains($0) }, hasExclusion: true),
        Query(id: "no-flower", text: "花が写っていない写真",
              truth: { !flowers.contains($0) }, hasExclusion: true),
        // --- S9 でレキシコンへ追補（以前は 0 件＝レキシコン外だった） ---
        Query(id: "instrument", text: "楽器の写真", truth: { instruments.contains($0) }),
    ]

    @Test("接地込みで広い語クエリの P/R/F1 を測る")
    func measure() async throws {
        guard FileManager.default.fileExists(atPath: Self.fixtureURL.path) else {
            print("SEARCHEVAL-CAL: skipped — フィクスチャ未生成（gen_centroid_fixture.py）")
            return
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixtureURL))
        let coherence = Self.coherenceClosure(fixture.centroidMutual)
        // クラスごとの枚数（キーを語彙表記に正規化）。
        let countByClass = Dictionary(uniqueKeysWithValues: fixture.imagesPerClass.map {
            ($0.key.replacingOccurrences(of: "_", with: " ").lowercased(), $0.value)
        })

        // --- コーパス合成: 1 枚 1 クラス・タグ網羅 86%（COCO ハーネスと同じ想定） ---
        var photos: [EnrichedPhoto] = []
        var tags: [String: [String]] = [:]
        var truthClass: [String: String] = [:]
        for (classIndex, name) in fixture.vocabulary.enumerated() {
            for n in 0..<(countByClass[name] ?? 0) {
                let refKey = "L-cal-\(classIndex)-\(n)"
                photos.append(EnrichedPhoto(id: refKey, captureDate: nil,
                                            latitude: nil, longitude: nil, placeName: nil))
                truthClass[refKey] = name
                var hash: UInt64 = 14_695_981_039_346_656_037
                for byte in refKey.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
                if Double(hash % 1000) / 1000.0 < 0.86 { tags[refKey] = [name] }
            }
        }
        print("SEARCHEVAL-CAL: --- corpus photos=\(photos.count) tagged=\(tags.count) "
              + "classes=\(fixture.vocabulary.count) ---")

        let now = Date(timeIntervalSince1970: 1_767_225_600)
        var scores: [SearchEvalQueries.Score] = []
        for query in Self.queries {
            // 本番と同一の経路: プレビュー解釈 → 語彙接地 → 検索 → 証拠ゲート。
            let saved = AIAlbumInterpreter.previewInterpretation(criteria: query.text, now: now)
            let grounded = VocabularyGrounding.apply(
                spec: saved.spec, vocabulary: fixture.vocabulary,
                similarity: { fixture.textImage[$0.lowercased()] ?? [] },
                coherenceZ: coherence)
            let searcher = AIAlbumSearcher(textEmbedder: nil)
            let (members, _) = await searcher.searchWithPool(
                baseLite: photos, spec: grounded, now: now, semanticText: "",
                photoTags: tags, loadPage: { _, _ in [] })
            let gated = grounded.allContentTerms.exclude.isEmpty
                ? members
                : AIAlbumVerificationCoordinator.evidenceGated(
                    members, tags: tags, faceCounts: [:], captions: [:],
                    excludeTerms: grounded.allContentTerms.exclude)

            let retrieved = Set(gated.map(\.id))
            let relevant = Set(truthClass.filter { query.truth($0.value) }.keys)
            let score = SearchEvalQueries.score(queryID: query.id, hasExclusion: query.hasExclusion,
                                                retrieved: retrieved, relevant: relevant)
            if query.knownLimitation == nil { scores.append(score) }
            let note = query.knownLimitation.map { "  [既知の限界: \($0)]" } ?? ""
            print(String(format: "SEARCHEVAL-CAL: %-11@ excl=%@ P=%.3f R=%.3f F1=%.3f  "
                         + "retrieved=%d relevant=%d FP=%d  include=%@%@",
                         query.id as NSString, query.hasExclusion ? "yes" : "no ",
                         score.precision, score.recall, score.f1,
                         score.retrieved, score.relevant, score.falsePositives,
                         grounded.allContentTerms.include.prefix(6).joined(separator: ",") as NSString,
                         note as NSString))
        }
        let macro = SearchEvalQueries.macro(scores)
        print(String(format: "SEARCHEVAL-CAL: MACRO P=%.3f R=%.3f F1=%.3f (接地込み・広い語)",
                     macro.precision, macro.recall, macro.f1))
        #expect(!scores.isEmpty)
    }
}
