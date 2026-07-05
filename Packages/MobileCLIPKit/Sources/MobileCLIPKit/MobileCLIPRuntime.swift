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

/// 同梱した CLIP（Core ML）を読み込み、画像／テキストを 512 次元埋め込みへ変換する。
/// モデルが見つからない（未同梱）場合は `isAvailable == false` で、呼び出し側は CLIP 無しの
/// 経路にフォールバックする。MLModel は推論スレッドセーフ。
///
/// ★ T1: **タワー別の遅延ロード**。従来は初回アクセスで両タワーを同時ロードし、実機で
/// 16〜35 秒＋メモリ +150MB 級のスパイクが起動直後（ユーザー操作の時間帯）に発生していた。
/// - テキスト塔（軽い方）: 検索/AI アルバム再評価/表示タグの概念構築が必要 → 必要時に即ロード
/// - 画像塔（重い方）: 背景の CLIP 埋め込みだけが必要 → **heavy ゲート内（電源＋アイドル）の
///   初回 encodeImage で初めてロード**される（呼び出し元 PhotoTagger がゲート済みのため）
final class MobileCLIPRuntime: @unchecked Sendable {
    static let shared = MobileCLIPRuntime()

    private static let log = LogChannel(subsystem: "com.mosaicphotos.MobileCLIPKit", label: "MobileCLIP")

    /// モデルが同梱されているか（＝機能が使えるか）。**ロードは発生させない**。
    /// 同梱だがロード失敗のケースは encode が nil を返し、機能無効と同等に安全に落ちる。
    let isAvailable: Bool

    private let config: MLModelConfiguration
    private let lock = NSLock()
    /// nil = 未試行 / .some(nil) = ロード失敗（再試行しない） / .some(model) = ロード済み。
    private var imageState: MLModel??
    private var textState: MLModel??
    private var imageInputName = ""
    private var imageOutputName = ""
    private var textInputName = ""
    private var textOutputName = ""
    private var imageConstraint: MLImageConstraint?

    private init() {
        let config = MLModelConfiguration()
        // シミュレータは MPSGraph/ANE バックエンドが無く .all だと Espresso 例外で推論が失敗するため
        // CPU に固定する（実機は .all のまま ANE/GPU を活用）。
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #endif
        self.config = config
        isAvailable = MobileCLIP.modelsBundled
        if !isAvailable {
            Self.log.info("CLIP models not bundled — AI search disabled")
        }
    }

    // MARK: - タワー別の遅延ロード（スレッドセーフ・失敗は一度だけ記録）

    private func loadTower(_ name: String, label: String) -> MLModel? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
            Self.log.error("CLIP \(label) tower not bundled")
            return nil
        }
        let started = Date()
        let model = try? MLModel(contentsOf: url, configuration: config)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let mb = currentMemoryFootprintMB().map { String(format: "%.0fMB", $0) } ?? "?"
        if model != nil {
            Self.log.info("CLIP \(label) tower loaded in \(ms)ms (footprint=\(mb))")
        } else {
            Self.log.error("CLIP \(label) tower bundled but failed to load")
        }
        return model
    }

    /// テキスト塔（軽い方）。検索・AI アルバム再評価・表示タグの概念埋め込みが使う。
    private func textModel() -> MLModel? {
        lock.lock(); defer { lock.unlock() }
        if let state = textState { return state }
        let model = loadTower("MobileCLIPTextS2", label: "text")
        if let model {
            textInputName = model.modelDescription.inputDescriptionsByName.keys.first ?? ""
            textOutputName = model.modelDescription.outputDescriptionsByName.keys.first ?? ""
        }
        textState = .some(model)
        return model
    }

    /// 画像塔（重い方）。背景の CLIP 埋め込み（heavy ゲート内）だけが使う。
    private func imageModel() -> MLModel? {
        lock.lock(); defer { lock.unlock() }
        if let state = imageState { return state }
        let model = loadTower("MobileCLIPImageS2", label: "image")
        if let model {
            let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? ""
            imageInputName = inputName
            imageOutputName = model.modelDescription.outputDescriptionsByName.keys.first ?? ""
            imageConstraint = model.modelDescription.inputDescriptionsByName[inputName]?.imageConstraint
        }
        imageState = .some(model)
        return model
    }

    // MARK: - 推論（MLModel はスレッドセーフ・ロック外で実行）

    /// トークン ID 列（長さ 77）→ 正規化済み 512 次元埋め込み。
    func encodeText(_ tokens: [Int32]) -> [Float]? {
        guard let textModel = textModel(),
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
        guard let imageModel = imageModel(), let imageConstraint,
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
