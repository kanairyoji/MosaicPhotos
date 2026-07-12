import CoreGraphics
import CoreML
import Foundation
import MosaicSupport

/// SmolVLM モデルが同梱されているか、ロードを発生させずに判定する（Developer Options 用）。
public enum VLM {
    public static var modelsBundled: Bool {
        Bundle.main.url(forResource: "VLMVision", withExtension: "mlmodelc") != nil
            && Bundle.main.url(forResource: "VLMDecoder", withExtension: "mlmodelc") != nil
    }
}

/// 同梱 SmolVLM（写真キャプション生成）のランタイム。
/// `scripts/build_smolvlm.sh` の生成物（MosaicPhotos/VLM/・.gitignore 対象）を遅延ロードする。
/// 未同梱でもアプリは動作し、キャプション（AI アルバムの精度向上）だけ無効化される。
///
/// 実行方式（変換スクリプトの割り切りと対）:
/// - デコーダは KV キャッシュ無しの固定長（256）全系列 forward。各ステップで全系列を流し、
///   末尾位置の logits を貪欲に選ぶ。135M・短出力（〜48 トークン）なら夜間バッチに十分。
/// - トークン埋め込みは vlm_embed_tokens.bin（fp16）を Swift 側でルックアップし、
///   `<image>` 位置に視覚埋め込み（VLMVision の出力）を差し込む。
final class VLMRuntime: @unchecked Sendable {
    static let shared = VLMRuntime()

    private static let log = LogChannel(subsystem: "com.mosaicphotos.MobileCLIPKit", label: "VLM")

    private struct Config: Decodable {
        let hiddenSize: Int
        let vocabSize: Int
        let seqLen: Int
        let maxNewTokens: Int
        let imageSize: Int
        let imageSeqLen: Int
        let imageTokenId: Int
        let fakeImageTokenId: Int
        let globalImgTokenId: Int
        let endOfUtteranceId: Int
        let eosTokenId: Int
        let promptPrefix: String
        let promptSuffix: String
    }

    /// 同梱判定（ロードを発生させない）。
    var isAvailable: Bool {
        Bundle.main.url(forResource: "VLMVision", withExtension: "mlmodelc") != nil
            && Bundle.main.url(forResource: "VLMDecoder", withExtension: "mlmodelc") != nil
            && Bundle.main.url(forResource: "vlm_config", withExtension: "json") != nil
    }

    private let box = LoadOnce<Loaded>()

    private struct Loaded {
        let config: Config
        let vision: CoreMLModelHandle   // 入力名・画像制約込み
        let decoder: MLModel
        let embeddings: Data            // fp16 (vocab, hidden) — 行ルックアップ
        let tokenizer: GPT2Tokenizer
    }

    private func load() -> Loaded? {
        box.get { Self.loadAll() }
    }

    private static func loadAll() -> Loaded? {
        let bundle = Bundle.main
        guard let cfgURL = bundle.url(forResource: "vlm_config", withExtension: "json"),
              let cfg = try? JSONDecoder().decode(Config.self, from: Data(contentsOf: cfgURL)),
              let visionURL = CoreMLModelLoader.bundledModelURL("VLMVision"),
              let decoderURL = CoreMLModelLoader.bundledModelURL("VLMDecoder"),
              let embedURL = bundle.url(forResource: "vlm_embed_tokens", withExtension: "bin"),
              let tokenizer = GPT2Tokenizer()
        else {
            log.info("VLM not bundled — captions disabled")
            return nil
        }
        let started = Date()
        let mlConfig = CoreMLModelLoader.makeConfiguration()
        guard let visionModel = try? MLModel(contentsOf: visionURL, configuration: mlConfig),
              let decoder = try? MLModel(contentsOf: decoderURL, configuration: mlConfig),
              // 56MB は mmap（alwaysMapped）で常駐を抑える。
              let embeddings = try? Data(contentsOf: embedURL, options: .alwaysMapped)
        else {
            log.error("VLM bundled but failed to load")
            return nil
        }
        guard embeddings.count == cfg.vocabSize * cfg.hiddenSize * 2 else {
            log.error("VLM embed size mismatch: \(embeddings.count)")
            return nil
        }
        let vision = CoreMLModelHandle(model: visionModel)
        guard vision.imageConstraint != nil else {
            log.error("VLM vision input constraint missing")
            return nil
        }
        log.info("VLM \(CoreMLModelLoader.loadStamp(since: started))")
        return Loaded(config: cfg, vision: vision, decoder: decoder, embeddings: embeddings,
                      tokenizer: tokenizer)
    }

    // MARK: - キャプション生成

    /// 写真 1 枚 → 短い英語キャプション（貪欲デコード・失敗は nil）。1〜2 秒/枚（実機）。
    func caption(for cgImage: CGImage) async -> String? {
        guard let m = load() else { return nil }
        let cfg = m.config

        // 1) 視覚埋め込み（1, imageSeqLen, hidden）
        guard let provider = m.vision.imageProvider(for: cgImage),
              let vout = try? await m.vision.model.prediction(from: provider),
              let imageEmbeds = vout.featureValue(for: "image_embeds")?.multiArrayValue
        else { return nil }

        // 2) プロンプトのトークン列（<image> ブロックを展開）
        var ids = m.tokenizer.encode(cfg.promptPrefix)
        ids.append(cfg.fakeImageTokenId)
        ids.append(cfg.globalImgTokenId)
        ids.append(contentsOf: Array(repeating: cfg.imageTokenId, count: cfg.imageSeqLen))
        ids.append(cfg.fakeImageTokenId)
        ids.append(contentsOf: m.tokenizer.encode(cfg.promptSuffix))
        guard ids.count + 4 < cfg.seqLen else { return nil }

        // 3) inputs_embeds を構築（fp16・<image> 位置に視覚埋め込みを差し込む）
        guard let embeds = try? MLMultiArray(shape: [1, NSNumber(value: cfg.seqLen),
                                                     NSNumber(value: cfg.hiddenSize)],
                                             dataType: .float16) else { return nil }
        let embedPtr = embeds.dataPointer.bindMemory(to: UInt16.self,
                                                     capacity: cfg.seqLen * cfg.hiddenSize)
        var imageRow = 0
        m.embeddings.withUnsafeBytes { (table: UnsafeRawBufferPointer) in
            let tablePtr = table.bindMemory(to: UInt16.self)
            let imgPtr = imageEmbeds.dataPointer.bindMemory(to: UInt16.self,
                                                            capacity: cfg.imageSeqLen * cfg.hiddenSize)
            for (pos, id) in ids.enumerated() {
                let dst = embedPtr + pos * cfg.hiddenSize
                if id == cfg.imageTokenId {
                    let src = imgPtr + imageRow * cfg.hiddenSize
                    dst.update(from: src, count: cfg.hiddenSize)
                    imageRow += 1
                } else {
                    let src = tablePtr.baseAddress! + id * cfg.hiddenSize
                    dst.update(from: src, count: cfg.hiddenSize)
                }
            }
        }

        // 4) 貪欲デコード（各ステップで全系列 forward・末尾 logits の argmax）
        var generated: [Int] = []
        var length = ids.count
        for _ in 0..<cfg.maxNewTokens {
            if Task.isCancelled { return nil }
            guard length < cfg.seqLen,
                  let dprov = try? MLDictionaryFeatureProvider(
                    dictionary: ["inputs_embeds": MLFeatureValue(multiArray: embeds)]),
                  let dout = try? await m.decoder.prediction(from: dprov),
                  let logits = dout.featureValue(for: "logits")?.multiArrayValue
            else { break }
            let next = Self.argmaxRow(logits, row: length - 1, vocab: cfg.vocabSize)
            if next == cfg.eosTokenId || next == cfg.endOfUtteranceId { break }
            generated.append(next)
            // 次トークンの埋め込みを書き込んで系列を 1 伸ばす。
            m.embeddings.withUnsafeBytes { (table: UnsafeRawBufferPointer) in
                let tablePtr = table.bindMemory(to: UInt16.self)
                let dst = embedPtr + length * cfg.hiddenSize
                dst.update(from: tablePtr.baseAddress! + next * cfg.hiddenSize, count: cfg.hiddenSize)
            }
            length += 1
        }
        let text = m.tokenizer.decode(generated)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// logits (1, seqLen, vocab) fp16 の指定行 argmax。
    private static func argmaxRow(_ logits: MLMultiArray, row: Int, vocab: Int) -> Int {
        let ptr = logits.dataPointer.bindMemory(to: UInt16.self, capacity: logits.count)
        let base = row * vocab
        var bestIndex = 0
        var bestValue = -Float.infinity
        for i in 0..<vocab {
            let v = Float(Float16(bitPattern: ptr[base + i]))
            if v > bestValue { bestValue = v; bestIndex = i }
        }
        return bestIndex
    }
}
