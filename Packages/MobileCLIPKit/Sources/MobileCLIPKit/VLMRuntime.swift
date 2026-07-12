import CoreGraphics
import CoreML
import Foundation
import MosaicSupport

/// VLM モデルが同梱されているか、ロードを発生させずに判定する（Developer Options 用）。
public enum VLM {
    public static var modelsBundled: Bool {
        Bundle.main.url(forResource: "VLMVision", withExtension: "mlmodelc") != nil
            && Bundle.main.url(forResource: "VLMDecoder", withExtension: "mlmodelc") != nil
    }
}

/// 同梱 VLM（写真キャプション生成）のランタイム。採用モデルは **Florence-2-base（MIT）**（ADR-32）。
/// `scripts/build_florence.sh` の生成物（MosaicPhotos/VLM/・.gitignore 対象）を遅延ロードする。
/// 未同梱でもアプリは動作し、キャプション（AI アルバムの精度向上・フル画像の AI description）だけ無効化される。
///
/// 実行方式（変換スクリプトの割り切りと対・encoder-decoder 型）:
/// - VLMVision（エンコーダ）: 画像1枚 → encoder 隠れ状態＋mask（タスク "<DETAILED_CAPTION>" と画像正規化を内包）。
/// - VLMDecoder（デコーダ）: decoder_input_ids[1,MAXLEN] を固定長で全系列 forward し、現在位置の logits を
///   貪欲に選ぶ（KV キャッシュ無し・動的長は ANE 非対応のため固定長＝SmolVLM 時代と同方式）。
/// - SmolVLM と違い**トークン埋め込み表は不要**（Florence デコーダはトークン ID を直接受ける）。復号のみ
///   `GPT2Tokenizer`（byte-level BPE・BART も同一写像）で行う。
final class VLMRuntime: @unchecked Sendable {
    static let shared = VLMRuntime()

    private static let log = LogChannel(subsystem: "com.mosaicphotos.MobileCLIPKit", label: "VLM")

    private struct Config: Decodable {
        let maxLen: Int
        let maxNewTokens: Int
        let vocabSize: Int
        let decoderStartTokenId: Int
        let eosTokenId: Int
        let padTokenId: Int
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
        let vision: CoreMLModelHandle   // 入力名・画像制約込み（image → encoder_hidden/encoder_mask）
        let decoder: MLModel
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
              let tokenizer = GPT2Tokenizer()
        else {
            log.info("VLM not bundled — captions disabled")
            return nil
        }
        let started = Date()
        // Florence は encoder-decoder（cross-attention）で、実機 ANE だと数値が壊れ全写真同一の
        // 無関係キャプションになる（Mac の CPU_AND_NE では正常）。ANE を避けて CPU+GPU で走らせる。
        let mlConfig = CoreMLModelLoader.makeConfiguration(avoidNeuralEngine: true)
        guard let visionModel = try? MLModel(contentsOf: visionURL, configuration: mlConfig),
              let decoder = try? MLModel(contentsOf: decoderURL, configuration: mlConfig)
        else {
            log.error("VLM bundled but failed to load")
            return nil
        }
        let vision = CoreMLModelHandle(model: visionModel)
        guard vision.imageConstraint != nil else {
            log.error("VLM vision input constraint missing")
            return nil
        }
        log.info("VLM(Florence) \(CoreMLModelLoader.loadStamp(since: started))")
        return Loaded(config: cfg, vision: vision, decoder: decoder, tokenizer: tokenizer)
    }

    // MARK: - キャプション生成

    /// 写真 1 枚 → 英語キャプション（貪欲デコード・失敗は nil）。実機 Core ML で 〜0.5 秒/枚。
    func caption(for cgImage: CGImage) async -> String? {
        guard let m = load() else { return nil }
        let cfg = m.config

        // 1) エンコーダ: 画像 → encoder_hidden [1,N,D], encoder_mask [1,N]
        guard let provider = m.vision.imageProvider(for: cgImage),
              let vout = try? await m.vision.model.prediction(from: provider),
              let encoderHidden = vout.featureValue(for: "encoder_hidden")?.multiArrayValue,
              let encoderMask = vout.featureValue(for: "encoder_mask")?.multiArrayValue
        else { return nil }
        // 診断: 実機で encoder 出力が非有限（fp16 NaN/Inf）だと cross-attention が死に、デコーダが
        // 画像を無視して言語モデルの地の文を吐く。ここで有限性を確認する。
        let ehStats = Self.finiteStats(encoderHidden)
        let emStats = Self.finiteStats(encoderMask)
        Diagnostics.mark("VLM encoder: hidden nonFinite=\(ehStats.nonFinite)/\(ehStats.count) min=\(ehStats.min) max=\(ehStats.max) | mask nonFinite=\(emStats.nonFinite)/\(emStats.count)")

        // 2) デコーダ入力バッファ（固定長・PAD 埋め・先頭に decoder_start）
        guard let decIds = try? MLMultiArray(shape: [1, NSNumber(value: cfg.maxLen)], dataType: .int32)
        else { return nil }
        let idPtr = decIds.dataPointer.bindMemory(to: Int32.self, capacity: cfg.maxLen)
        for i in 0..<cfg.maxLen { idPtr[i] = Int32(cfg.padTokenId) }
        idPtr[0] = Int32(cfg.decoderStartTokenId)

        // 3) 貪欲デコード（各ステップで全系列 forward・現在位置 step の logits を argmax）
        var generated: [Int] = []
        let steps = min(cfg.maxNewTokens, cfg.maxLen - 1)
        for step in 0..<steps {
            if Task.isCancelled { return nil }
            guard let prov = try? MLDictionaryFeatureProvider(dictionary: [
                "decoder_input_ids": MLFeatureValue(multiArray: decIds),
                "encoder_hidden": MLFeatureValue(multiArray: encoderHidden),
                "encoder_mask": MLFeatureValue(multiArray: encoderMask),
            ]),
                  let dout = try? await m.decoder.prediction(from: prov),
                  let logits = dout.featureValue(for: "logits")?.multiArrayValue
            else { break }
            let next = Self.argmaxRow(logits, row: step, vocab: cfg.vocabSize)
            if next == cfg.eosTokenId { break }
            generated.append(next)
            idPtr[step + 1] = Int32(next)   // 系列を 1 伸ばす
        }

        let text = m.tokenizer.decode(generated)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let idsStr = generated.prefix(8).map(String.init).joined(separator: " ")
        Diagnostics.mark("VLM caption ids=[\(idsStr)] text=\(text.prefix(60))")
        return text.isEmpty ? nil : text
    }

    /// MLMultiArray の有限性統計（非有限数・最小/最大）。fp16/fp32 両対応。診断用。
    private static func finiteStats(_ a: MLMultiArray) -> (count: Int, nonFinite: Int, min: Float, max: Float) {
        let n = a.count
        var nonFinite = 0
        var mn = Float.infinity, mx = -Float.infinity
        func acc(_ v: Float) {
            if !v.isFinite { nonFinite += 1 } else { if v < mn { mn = v }; if v > mx { mx = v } }
        }
        switch a.dataType {
        case .float16:
            let ptr = a.dataPointer.bindMemory(to: UInt16.self, capacity: n)
            for i in 0..<n { acc(Float(Float16(bitPattern: ptr[i]))) }
        case .float32:
            let ptr = a.dataPointer.bindMemory(to: Float.self, capacity: n)
            for i in 0..<n { acc(ptr[i]) }
        default:
            let ptr = a.dataPointer.bindMemory(to: Double.self, capacity: n)
            for i in 0..<n { acc(Float(ptr[i])) }
        }
        return (n, nonFinite, mn.isFinite ? mn : 0, mx.isFinite ? mx : 0)
    }

    /// logits (1, maxLen, vocab) fp16 の指定行 argmax。
    private static func argmaxRow(_ logits: MLMultiArray, row: Int, vocab: Int) -> Int {
        let base = row * vocab
        var bestIndex = 0
        var bestValue = -Float.infinity
        // デコーダは fp32（実機の fp16 argmax 反転を避けるため）だが、念のため両 dtype に対応する。
        switch logits.dataType {
        case .float32:
            let ptr = logits.dataPointer.bindMemory(to: Float.self, capacity: logits.count)
            for i in 0..<vocab where ptr[base + i] > bestValue { bestValue = ptr[base + i]; bestIndex = i }
        default:
            let ptr = logits.dataPointer.bindMemory(to: UInt16.self, capacity: logits.count)
            for i in 0..<vocab {
                let v = Float(Float16(bitPattern: ptr[base + i]))
                if v > bestValue { bestValue = v; bestIndex = i }
            }
        }
        return bestIndex
    }
}
