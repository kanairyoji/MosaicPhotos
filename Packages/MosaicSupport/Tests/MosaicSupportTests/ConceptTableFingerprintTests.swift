import Foundation
import Testing
@testable import MosaicSupport

/// ⚠️ ここが「いつ表を捨てるか」の正本。表示タグの概念埋め込みをディスクに置いたので
/// （実機で起動ごとに 13 秒・+260MB を払っていた・diagnostics-96）、**捨て損ねると
/// 古いモデルのベクトルで比較して静かに変なタグが出る**。気づけない壊れ方なので、
/// 「何が変われば鍵が変わるか」を 1 つずつ固定する。
@Suite("概念表を捨てる条件")
struct ConceptTableFingerprintTests {

    private func fp(version: Int = 1,
                    model: String? = "ViT-B-32/datacomp/d512/c77",
                    prompts: [String] = ["a photo of cat", "a photo of dog"],
                    vocab: Int? = 1_234_567) -> String? {
        ConceptTableFingerprint.make(formatVersion: version, modelIdentity: model,
                                     prompts: prompts, tokenizerSize: vocab)
    }

    @Test("同じ入力なら同じ鍵（作り直しても読める）")
    func deterministic() {
        #expect(fp() == fp())
        #expect(fp() != nil)
    }

    // MARK: - 変われば捨てる

    /// ⚠️ 本命。モデルを差し替えたら同じ語でもベクトルは別物。
    @Test("モデルが変われば鍵が変わる")
    func modelChangeInvalidates() {
        #expect(fp(model: "ViT-B-32/datacomp/d512/c77") != fp(model: "ViT-B-16/datacomp/d512/c77"))
        // 重みだけ違う場合も別物。
        #expect(fp(model: "ViT-B-32/datacomp/d512/c77") != fp(model: "ViT-B-32/laion/d512/c77"))
        // 次元・文脈長も鍵に入っている。
        #expect(fp(model: "ViT-B-32/datacomp/d512/c77") != fp(model: "ViT-B-32/datacomp/d768/c77"))
    }

    @Test("語が増えれば鍵が変わる")
    func addedConceptInvalidates() {
        #expect(fp(prompts: ["a photo of cat"]) != fp(prompts: ["a photo of cat", "a photo of dog"]))
    }

    @Test("語が減れば鍵が変わる")
    func removedConceptInvalidates() {
        #expect(fp(prompts: ["a photo of cat", "a photo of dog"]) != fp(prompts: ["a photo of cat"]))
    }

    @Test("語を書き換えれば鍵が変わる")
    func editedConceptInvalidates() {
        #expect(fp(prompts: ["a photo of cat"]) != fp(prompts: ["a photo of kitten"]))
    }

    /// ⚠️ 並びも鍵に入る。読む側は語を持たず**順序で対応づける**ので、並びが変わった表を
    /// そのまま読むと**全部のタグがずれる**（cat のベクトルに dog の名前が付く）。
    @Test("語の並びが変われば鍵が変わる")
    func reorderInvalidates() {
        #expect(fp(prompts: ["a photo of cat", "a photo of dog"])
                != fp(prompts: ["a photo of dog", "a photo of cat"]))
    }

    /// ⚠️ 語リストだけを鍵にすると取りこぼす形。テンプレートを変えたら別のベクトルになる。
    @Test("プロンプトのテンプレートが変われば鍵が変わる")
    func templateChangeInvalidates() {
        #expect(fp(prompts: ["a photo of cat"]) != fp(prompts: ["a picture of cat"]))
        #expect(fp(prompts: ["a photo of cat"]) != fp(prompts: ["cat"]))
    }

    @Test("語彙ファイルが変われば鍵が変わる")
    func tokenizerChangeInvalidates() {
        #expect(fp(vocab: 1_234_567) != fp(vocab: 1_234_568))
        #expect(fp(vocab: 1_234_567) != fp(vocab: nil))
    }

    @Test("ファイル形式の版が変われば鍵が変わる")
    func formatVersionInvalidates() {
        #expect(fp(version: 1) != fp(version: 2))
    }

    /// ⚠️ **境界が曖昧にならないこと**。区切りを挟まないと連結が同じになり、
    /// 語の切り方を変えても同じ鍵になってしまう（`["ab","c"]` と `["a","bc"]`）。
    @Test("語の切り方が変われば鍵が変わる（連結して同じでも区別する）")
    func promptBoundariesMatter() {
        #expect(fp(prompts: ["ab", "c"]) != fp(prompts: ["a", "bc"]))
        #expect(fp(prompts: ["ab", "c"]) != fp(prompts: ["abc"]))
    }

    // MARK: - 使わない場合

    /// ⚠️ モデルを識別できないなら**保存も読み込みもしない**。識別できないまま置くと、
    /// 差し替えたときに古い表を読み続ける（この仕組みでいちばん避けたい失敗）。
    @Test("モデルを識別できなければ鍵を作らない")
    func noModelIdentityMeansNoCache() {
        #expect(fp(model: nil) == nil)
    }

    @Test("語が空でも鍵は作れる（表が空なのは別の問題）")
    func emptyPromptsStillKeyed() {
        #expect(fp(prompts: []) != nil)
        #expect(fp(prompts: []) != fp(prompts: ["a photo of cat"]))
    }

    /// ファイル名に使える形であること（16 桁の 16 進）。
    @Test("鍵はファイル名に使える 16 桁の 16 進")
    func keyIsFilenameSafe() {
        let key = fp()
        #expect(key?.count == 16)
        #expect(key?.allSatisfy { $0.isHexDigit } == true)
    }
}
