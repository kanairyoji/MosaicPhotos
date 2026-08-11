import Foundation
import Testing
@testable import AutoAlbumCore

/// 語彙接地の**近さの計算方法**を比較計測する（ADR-101）。手動実行専用・データ無ければスキップ。
///
/// 何を比べるか: 同じ正解に対して
///  - `textText`: クエリ語 × **クラス名** の CLIP テキスト類似度（当初の実装・不十分と判明）
///  - `textImage`: クエリ語 × **クラス重心**（そのクラスの写真の CLIP 画像埋め込みの平均）
/// を通し、`VocabularyGrounding` の規則で展開した結果の precision を出す。
///
/// 正解は「上位概念 → その下位概念」を人手で書いた保守的な集合。**実装が発見すべきもの**を
/// 評価側が持つ形（実装側には一切の対応表を持たせない）。
///
/// 実行:
/// ```
/// scripts/fetch_search_eval_datasets.sh
/// source .mobileclip_build/venv/bin/activate && python scripts/gen_centroid_fixture.py
/// cd Packages/AutoAlbumCore && swift test --filter CentroidGroundingEval
/// ```
@Suite("CentroidGroundingEval (Caltech-101・接地の比較)")
struct CentroidGroundingEvalTests {

    private struct Fixture: Decodable {
        let vocabulary: [String]
        let textText: [String: [Double]]
        let textImage: [String: [Double]]
        /// 重心どうしの相互類似（S6 の凝集度規則用）。
        let centroidMutual: [[Double]]?
    }

    private static var fixtureURL: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent(".search_eval/centroids.json")
    }

    /// 上位概念 → 正しい下位概念（Caltech-101 のクラス名）。**保守的に**明白なものだけ入れる。
    private static let truth: [String: Set<String>] = [
        "food": ["pizza", "strawberry", "lobster", "crab"],
        "musical instrument": ["accordion", "electric guitar", "euphonium", "grand piano",
                               "mandolin", "saxophone", "gramophone"],
        "vehicle": ["airplanes", "car side", "ferry", "helicopter", "ketch", "schooner",
                    "motorbikes"],
        "flower": ["lotus", "sunflower", "water lilly"],
        "insect": ["ant", "butterfly", "dragonfly", "mayfly", "tick"],
        "bird": ["emu", "flamingo", "flamingo head", "ibis", "pigeon", "rooster"],
        "furniture": ["chair", "windsor chair", "lamp"],
        // 高原（広い語・S6）: 該当クラスが多すぎて突出しない形。凝集度規則で接地されること。
        "animal": ["emu", "flamingo", "flamingo head", "okapi", "llama", "cougar body",
                   "cougar face", "beaver", "platypus", "wild cat", "hedgehog", "crocodile",
                   "crocodile head", "gerenuk", "elephant", "kangaroo", "dolphin", "ibis",
                   "sea horse", "rhino", "panda", "octopus", "dalmatian", "bass", "pigeon",
                   "rooster", "butterfly", "ant", "dragonfly", "mayfly", "crab", "lobster",
                   "crayfish", "scorpion", "leopards", "hawksbill", "brontosaurus", "stegosaurus"],
        // 語彙にそのまま在る語（完全一致が効くかの対照）
        "pizza": ["pizza"],
        "laptop": ["laptop"],
        "umbrella": ["umbrella"],
    ]

    @Test("重心（text↔image）の方がクラス名（text↔text）より正しく展開する")
    func compareGroundingMethods() throws {
        guard FileManager.default.fileExists(atPath: Self.fixtureURL.path) else {
            print("CENTROIDEVAL: skipped — フィクスチャ未生成"
                  + "（scripts/gen_centroid_fixture.py を実行）")
            return
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixtureURL))

        /// ⚠️ precision だけで比べてはいけない。接地を諦めた語は「間違えない」ので precision は
        ///    1.0 になる（クラス名版は完全一致の 3 語しか接地せず precision 1.0 だった）。
        ///    正解集合に対する **F1**（接地しなければ 0）で見る。
        func evaluate(_ table: [String: [Double]], label: String,
                      coherence: CoherenceContext? = nil) -> (f1: Double, grounded: Int) {
            var f1s: [Double] = []
            var groundedCount = 0
            for (term, expected) in Self.truth.sorted(by: { $0.key < $1.key }) {
                guard let row = table[term] else { continue }
                let g = VocabularyGrounding.ground(terms: [term], vocabulary: fixture.vocabulary,
                                                   similarity: { _ in row },
                                                   coherence: coherence)[0]
                guard g.isGrounded else {
                    f1s.append(0)
                    print("CENTROIDEVAL: \(label) \(term): 接地せず（F1=0）")
                    continue
                }
                groundedCount += 1
                let correct = g.expanded.filter { expected.contains($0) }.count
                let precision = Double(correct) / Double(g.expanded.count)
                let recall = Double(correct) / Double(expected.count)
                let f1 = (precision + recall) == 0 ? 0 : 2 * precision * recall / (precision + recall)
                f1s.append(f1)
                print(String(format: "CENTROIDEVAL: %-8@ %-19@ P=%.2f R=%.2f F1=%.2f  → %@",
                             label as NSString, term as NSString, precision, recall, f1,
                             g.expanded.joined(separator: ", ") as NSString))
            }
            let macro = f1s.isEmpty ? 0 : f1s.reduce(0, +) / Double(f1s.count)
            return (macro, groundedCount)
        }

        let tt = evaluate(fixture.textText, label: "textText")
        let ti = evaluate(fixture.textImage, label: "centroid",
                          coherence: CoherenceFixtureSupport.coherenceContext(fixture.centroidMutual))
        print(String(format: "CENTROIDEVAL: MACRO textText F1=%.3f (接地 %d/%d)",
                     tt.f1, tt.grounded, Self.truth.count))
        print(String(format: "CENTROIDEVAL: MACRO centroid F1=%.3f (接地 %d/%d)  ← 採用",
                     ti.f1, ti.grounded, Self.truth.count))

        // ⚠️ ここは**回帰の固定**でもある。重心版がクラス名版を下回ったら設計判断が崩れている。
        #expect(ti.f1 > tt.f1, "重心版がクラス名版に負けている（ADR-101 の前提が崩れた）")
        #expect(ti.grounded >= tt.grounded, "重心版の方が接地できる語が少ない")
    }

    /// 雑音語（視覚概念として語彙に相当物が無い語）は**接地されない**こと（S6 の負例）。
    /// 高原規則（凝集度）を導入しても、雑音の高原が門を通らないことを固定する。
    @Test("雑音語は高原規則でも接地されない")
    func noiseTermsStayUngrounded() throws {
        guard FileManager.default.fileExists(atPath: Self.fixtureURL.path) else { return }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixtureURL))
        let coherence = CoherenceFixtureSupport.coherenceContext(fixture.centroidMutual)
        for term in ["nostalgia", "happiness", "freedom"] {
            guard let row = fixture.textImage[term] else { continue }
            let g = VocabularyGrounding.ground(terms: [term], vocabulary: fixture.vocabulary,
                                               similarity: { _ in row }, coherence: coherence)[0]
            #expect(!g.isGrounded, "雑音語 \(term) が接地された: \(g.expanded)")
        }
    }
}
