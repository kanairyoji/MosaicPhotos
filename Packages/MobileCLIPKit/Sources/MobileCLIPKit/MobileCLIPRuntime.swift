import CoreML
import MosaicSupport
import UIKit

/// MobileCLIP モデル（.mlmodelc）が同梱されているか、ロードを発生させずに判定する。
/// Developer Options の可視化用（ロードは重いので強制しない）。
public enum MobileCLIP {
    public static var modelsBundled: Bool {
        Bundle.main.url(forResource: "MobileCLIPImageS2", withExtension: "mlmodelc") != nil
            && Bundle.main.url(forResource: "MobileCLIPTextS2", withExtension: "mlmodelc") != nil
    }
}

/// 同梱した MobileCLIP-S2（Core ML）を読み込み、画像／テキストを 512 次元埋め込みへ変換する。
/// モデルが見つからない（未同梱）場合は `isAvailable == false` で、呼び出し側は CLIP 無しの
/// 経路（Vision タグ＋NL 拡張）にフォールバックする。MLModel は推論スレッドセーフ。
final class MobileCLIPRuntime: @unchecked Sendable {
    static let shared = MobileCLIPRuntime()

    private static let log = LogChannel(subsystem: "com.mosaicphotos.MobileCLIPKit", label: "MobileCLIP")

    let isAvailable: Bool

    private let imageModel: MLModel?
    private let textModel: MLModel?
    private let imageInputName: String
    private let imageOutputName: String
    private let textInputName: String
    private let textOutputName: String
    private let imageConstraint: MLImageConstraint?

    private init() {
        let config = MLModelConfiguration()
        // シミュレータは MPSGraph/ANE バックエンドが無く .all だと Espresso 例外で推論が失敗するため
        // CPU に固定する（実機は .all のまま ANE/GPU を活用）。
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #endif
        func load(_ name: String) -> MLModel? {
            guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else { return nil }
            return try? MLModel(contentsOf: url, configuration: config)
        }
        let started = Date()
        let img = load("MobileCLIPImageS2")
        let txt = load("MobileCLIPTextS2")
        imageModel = img
        textModel = txt
        // 起動後の動的ロード結果を診断ログに残す（実機でロード失敗・メモリ問題を追えるように）。
        let bundled = MobileCLIP.modelsBundled
        if img != nil && txt != nil {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let mb = currentMemoryFootprintMB().map { String(format: "%.0fMB", $0) } ?? "?"
            Self.log.info("CLIP models loaded in \(ms)ms (footprint=\(mb))")
        } else if bundled {
            Self.log.error("CLIP models bundled but failed to load (image=\(img != nil), text=\(txt != nil))")
        } else {
            Self.log.info("CLIP models not bundled — AI search disabled")
        }
        imageInputName = img?.modelDescription.inputDescriptionsByName.keys.first ?? ""
        imageOutputName = img?.modelDescription.outputDescriptionsByName.keys.first ?? ""
        textInputName = txt?.modelDescription.inputDescriptionsByName.keys.first ?? ""
        textOutputName = txt?.modelDescription.outputDescriptionsByName.keys.first ?? ""
        imageConstraint = img?.modelDescription.inputDescriptionsByName[img?.modelDescription
            .inputDescriptionsByName.keys.first ?? ""]?.imageConstraint
        isAvailable = (img != nil && txt != nil)
    }

    /// トークン ID 列（長さ 77）→ 正規化済み 512 次元埋め込み。
    func encodeText(_ tokens: [Int32]) -> [Float]? {
        guard let textModel,
              let arr = try? MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32)
        else { return nil }
        let ptr = arr.dataPointer.bindMemory(to: Int32.self, capacity: tokens.count)
        for i in tokens.indices { ptr[i] = tokens[i] }
        guard let provider = try? MLDictionaryFeatureProvider(
                dictionary: [textInputName: MLFeatureValue(multiArray: arr)]),
              let out = try? textModel.prediction(from: provider),
              let m = out.featureValue(for: textOutputName)?.multiArrayValue
        else { return nil }
        return floats(m)
    }

    /// 画像 → 正規化済み 512 次元埋め込み。リサイズ/画素変換はモデルの画像制約に従い自動。
    func encodeImage(_ cgImage: CGImage) -> [Float]? {
        guard let imageModel, let imageConstraint,
              let fv = try? MLFeatureValue(cgImage: cgImage, constraint: imageConstraint, options: nil),
              let provider = try? MLDictionaryFeatureProvider(dictionary: [imageInputName: fv]),
              let out = try? imageModel.prediction(from: provider),
              let m = out.featureValue(for: imageOutputName)?.multiArrayValue
        else { return nil }
        return floats(m)
    }

    /// MLMultiArray → [Float]。NaN/Inf が混じったベクトルは壊れているので nil にする
    /// （CLIP のコサイン類似が NaN 化し、検索・ゼロショットが全滅するのを防ぐ）。
    private func floats(_ m: MLMultiArray) -> [Float]? {
        let result = (0..<m.count).map { Float(truncating: m[$0]) }
        return result.allSatisfy { $0.isFinite } ? result : nil
    }
}
