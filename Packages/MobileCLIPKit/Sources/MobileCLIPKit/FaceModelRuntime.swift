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
    private let handle: CoreMLModelHandle?

    private init() {
        let config = CoreMLModelLoader.makeConfiguration()
        var loaded: MLModel?
        if let url = CoreMLModelLoader.bundledModelURL("FaceEmbedder") {
            loaded = try? MLModel(contentsOf: url, configuration: config)
        }
        handle = loaded.map(CoreMLModelHandle.init)
        isAvailable = loaded != nil
        if loaded != nil {
            Self.log.info("face model loaded")
        } else if FaceModel.modelBundled {
            Self.log.error("face model bundled but failed to load")
        } else {
            Self.log.info("face model not bundled — people disabled")
        }
    }

    /// 顔切り抜き画像 → 512 次元 L2 正規化埋め込み。NaN/Inf は壊れとみなし nil
    /// （有限性ガードは CoreMLModelHandle 側で共通に行う）。
    func embed(_ cgImage: CGImage) -> [Float]? {
        handle?.predictVector(from: cgImage)
    }
}
