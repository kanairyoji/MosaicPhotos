import AutoAlbumCore
import UIKit
import Vision
import XCTest
@testable import MobileCLIPKit
@testable import MosaicPhotos

/// 検索品質ハーネス（手動実行専用・Recall@k のベースライン計測）。
/// Imagenette フィクスチャ（scripts/gen_eval_fixture.py が CLIP 画像埋め込みを前計算）＋
/// クエリ集（scripts/eval_queries.json・正解ラベル付き）に対して、**本番と同じ検索パイプライン**
/// （決定的プレビュー解釈 → タグ＋CLIP＋字句の RRF 融合）を回し、Recall@20 等を出力する。
///
/// - 画像埋め込みは Mac で前計算（シミュレータの画像タワーは fp16 NaN のため）。
///   テキストタワー・トークナイザ・解釈・融合は**実物**を使う。
/// - FM（LLM 解釈・審査・翻訳）はテスト環境で使えないため、解釈=プレビュー（決定的）、
///   翻訳=クエリ集の `en` 欄（夜間 FM 翻訳の代替）、場所条件=`place` ヒントで代替する。
/// - フィクスチャが無い環境（CI 等）ではスキップ。実行:
///   `python scripts/gen_eval_fixture.py` 後に
///   `xcodebuild test -scheme MosaicPhotos -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///      -only-testing:MosaicPhotosTests/SearchQualityTests`
final class SearchQualityTests: XCTestCase {

    // MARK: - Fixture types

    private struct Fixture: Decodable {
        struct Photo: Decodable { let refKey: String; let wnid: String; let file: String; let vec: String }
        let photos: [Photo]
    }

    private struct QueryFile: Decodable {
        struct Meta: Decodable { let place: String; let people: [String]? }
        struct Query: Decodable {
            let id: String, category: String, text: String, en: String
            let expected: [String]
            let place: [String]?
            /// 夜間 FM(expandProbes) 生成の代替（マルチプローブ採点 ADR-35 用）。
            let probes: [String]?
        }
        let metadata: [String: Meta]
        let queries: [Query]
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - Test

    func testSearchQualityBaseline() async throws {
        try XCTSkipUnless(MobileCLIPRuntime.shared.isAvailable, "MobileCLIP models not bundled — skipping")
        let root = Self.repoRoot
        let fixtureURL = root.appendingPathComponent(".mobileclip_build/eval/fixture.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixtureURL.path),
                          "fixture missing — run scripts/gen_eval_fixture.py first")

        var report: [String] = []
        func emit(_ line: String) { print(line); report.append(line) }

        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        let queryFile = try JSONDecoder().decode(
            QueryFile.self, from: Data(contentsOf: root.appendingPathComponent("scripts/eval_queries.json")))

        // クラス→index（日付合成用・wnid 昇順）
        let wnids = Array(Set(fixture.photos.map(\.wnid))).sorted()
        let classIndex = Dictionary(uniqueKeysWithValues: wnids.enumerated().map { ($1, $0) })

        // EnrichedPhoto（メタ合成: 日付=2024/(classIdx+1)月・場所/人物=クエリ集の metadata）
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var photos: [EnrichedPhoto] = []
        var vectors: [(refKey: String, clipVector: Data)] = []
        for (i, p) in fixture.photos.enumerated() {
            let meta = queryFile.metadata[p.wnid]
            let month = (classIndex[p.wnid] ?? 0) + 1
            let date = cal.date(from: DateComponents(year: 2024, month: month, day: (i % 27) + 1, hour: 12))!
            photos.append(EnrichedPhoto(id: p.refKey, captureDate: date, latitude: nil, longitude: nil,
                                        placeName: meta?.place,
                                        country: meta?.place.split(separator: ",").last.map {
                                            $0.trimmingCharacters(in: .whitespaces) },
                                        people: meta?.people ?? []))
            guard let raw = Data(base64Encoded: p.vec) else { XCTFail("bad vec \(p.refKey)"); continue }
            vectors.append((refKey: p.refKey, clipVector: raw))
        }
        vectors.sort { $0.refKey < $1.refKey }

        // Vision シーンタグ（本番と同じ classify・初回のみ計算してキャッシュ）
        let tags = try loadOrComputeTags(fixture: fixture, root: root)
        let taggedCount = tags.values.filter { !$0.isEmpty }.count
        emit("EVAL tags: \(taggedCount)/\(fixture.photos.count) photos have tags")

        let searcher = AIAlbumSearcher(textEmbedder: MobileCLIPTextEmbedder())
        let now = cal.date(from: DateComponents(year: 2024, month: 12, day: 15))!
        let namedPeople = ["木村太郎", "木村花子"]
        let byWnid = Dictionary(grouping: fixture.photos, by: \.wnid)

        struct Row { let id, category: String; let recall20, memberP, memberR: Double; let members: Int }
        var rows: [Row] = []

        for q in queryFile.queries {
            // 解釈: 本番の即時プレビューと同じ決定的経路＋place ヒント（夜間 FM 解釈の代替）
            var spec = AIAlbumInterpreter.previewInterpretation(
                criteria: q.text, now: now, namedPeople: namedPeople).spec
            if let place = q.place, !place.isEmpty {
                if spec.clauses.isEmpty {
                    spec.clauses = [QueryClause([.place(place)])]
                } else {
                    spec.clauses = spec.clauses.map { QueryClause($0.conditions + [.place(place)]) }
                }
            }
            let (members, pool) = await searcher.searchWithPool(
                baseLite: photos, spec: spec, now: now, semanticText: q.en,
                probes: q.probes ?? [],
                photoTags: tags,
                loadPage: { offset, limit in
                    guard offset < vectors.count else { return [] }
                    return Array(vectors[offset..<min(offset + limit, vectors.count)])
                })

            let expectedSet = Set(q.expected.flatMap { byWnid[$0] ?? [] }.map(\.refKey))
            let ranked = pool.sorted { $0.value > $1.value }.map(\.key)
            let top20 = Set(ranked.prefix(20))
            let recall20 = expectedSet.isEmpty ? 0
                : Double(top20.intersection(expectedSet).count) / Double(expectedSet.count)
            let memberSet = Set(members.map(\.id))
            let hit = memberSet.intersection(expectedSet).count
            let memberP = memberSet.isEmpty ? 0 : Double(hit) / Double(memberSet.count)
            let memberR = expectedSet.isEmpty ? 0 : Double(hit) / Double(expectedSet.count)
            rows.append(Row(id: q.id, category: q.category, recall20: recall20,
                            memberP: memberP, memberR: memberR, members: members.count))
            emit(String(format: "EVAL %@ [%@] R@20=%.2f memberP=%.2f memberR=%.2f members=%d  \"%@\"",
                         q.id, q.category, recall20, memberP, memberR, members.count, q.text))
        }

        // カテゴリ別・全体の集計
        let categories = Array(Set(rows.map(\.category))).sorted()
        emit("EVAL ===== category means =====")
        for c in categories {
            let sub = rows.filter { $0.category == c }
            let r = sub.map(\.recall20).reduce(0, +) / Double(sub.count)
            let p = sub.map(\.memberP).reduce(0, +) / Double(sub.count)
            let mr = sub.map(\.memberR).reduce(0, +) / Double(sub.count)
            emit(String(format: "EVAL   %-13@ (n=%2d)  R@20=%.2f memberP=%.2f memberR=%.2f",
                         c as NSString, sub.count, r, p, mr))
        }
        let overallR = rows.map(\.recall20).reduce(0, +) / Double(rows.count)
        let overallP = rows.map(\.memberP).reduce(0, +) / Double(rows.count)
        let overallMR = rows.map(\.memberR).reduce(0, +) / Double(rows.count)
        emit(String(format: "EVAL OVERALL (n=%d)  R@20=%.2f memberP=%.2f memberR=%.2f",
                     rows.count, overallR, overallP, overallMR))

        try? report.joined(separator: "\n")
            .write(to: root.appendingPathComponent(".mobileclip_build/eval/report.txt"),
                   atomically: true, encoding: .utf8)

        // 回帰の床（緩め）: 全体 R@20 が極端に壊れたら気付けるように。チューニングの厳密な合否は
        // 出力の比較で行う（レポートは model-evaluations.md に記録）。
        XCTAssertGreaterThan(overallR, 0.2, "overall Recall@20 collapsed — search pipeline regression?")
    }

    // MARK: - Vision tags (cached)

    private func loadOrComputeTags(fixture: Fixture, root: URL) throws -> [String: [String]] {
        let cacheURL = root.appendingPathComponent(".mobileclip_build/eval/tags.json")
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([String: [String]].self, from: data),
           cached.count == fixture.photos.count {
            return cached
        }
        var tags: [String: [String]] = [:]
        for p in fixture.photos {
            let path = root.appendingPathComponent(p.file).path
            guard let cg = UIImage(contentsOfFile: path)?.cgImage else { tags[p.refKey] = []; continue }
            tags[p.refKey] = VisionTagAdapter.classify(cg)   // 本番と同一の足切り（precision 0.9）
        }
        try JSONEncoder().encode(tags).write(to: cacheURL)
        return tags
    }
}
