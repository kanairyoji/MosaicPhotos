import CoreML
import MosaicSupport
import UIKit

/// 顔認識モデル（FaceEmbedder.mlmodelc）が同梱されているか、ロードを発生させずに判定する。
public enum FaceModel {
    public static var modelBundled: Bool {
        Bundle.main.url(forResource: "FaceEmbedder", withExtension: "mlmodelc") != nil
    }
}

/// 同梱した顔認識モデル（Core ML・facenet InceptionResnetV1）を読み込み、顔切り抜き画像を
/// 512 次元 L2 正規化埋め込みへ変換する。未同梱なら `isAvailable == false` でピープルは無効。
/// 入力リサイズ（160x160）と正規化はモデル側に内包（`MLFeatureValue(cgImage:constraint:)` が自動）。
final class FaceModelRuntime: @unchecked Sendable {
    static let shared = FaceModelRuntime()
    private static let log = LogChannel(subsystem: "com.mosaicphotos.MobileCLIPKit", label: "Faces")

    let isAvailable: Bool
    private let model: MLModel?
    private let inputName: String
    private let outputName: String
    private let constraint: MLImageConstraint?

    private init() {
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #endif
        var loaded: MLModel?
        if let url = Bundle.main.url(forResource: "FaceEmbedder", withExtension: "mlmodelc") {
            loaded = try? MLModel(contentsOf: url, configuration: config)
        }
        model = loaded
        inputName = loaded?.modelDescription.inputDescriptionsByName.keys.first ?? ""
        outputName = loaded?.modelDescription.outputDescriptionsByName.keys.first ?? ""
        constraint = loaded?.modelDescription.inputDescriptionsByName[inputName]?.imageConstraint
        isAvailable = loaded != nil
        if loaded != nil {
            Self.log.info("face model loaded")
        } else if FaceModel.modelBundled {
            Self.log.error("face model bundled but failed to load")
        } else {
            Self.log.info("face model not bundled — people disabled")
        }
    }

    /// 顔切り抜き画像 → 512 次元 L2 正規化埋め込み。NaN/Inf は壊れとみなし nil。
    func embed(_ cgImage: CGImage) -> [Float]? {
        guard let model, let constraint,
              let fv = try? MLFeatureValue(cgImage: cgImage, constraint: constraint, options: nil),
              let provider = try? MLDictionaryFeatureProvider(dictionary: [inputName: fv]),
              let out = try? model.prediction(from: provider),
              let arr = out.featureValue(for: outputName)?.multiArrayValue
        else { return nil }
        let v = (0..<arr.count).map { Float(truncating: arr[$0]) }
        return v.allSatisfy { $0.isFinite } ? v : nil
    }
}
