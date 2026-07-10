import CoreGraphics
import CoreML
import Foundation
import MosaicSupport

/// 3 つの Core ML ランタイム（MobileCLIP / VLM / FaceModel）が共有するプリミティブ。
/// - 設定（シミュレータ CPU 固定）・バンドル探索・ロード時間/フットプリントの診断ログ
/// - 単一入出力モデルの入出力名・画像制約の抽出と画像推論（`CoreMLModelHandle`）
/// - NSLock ＋失敗センチネルの遅延ロード（`LoadOnce`）
/// 各ランタイム固有の部分（CLIP のバッチ/テキスト塔・VLM の固定長デコード等）は共通化しない。
enum CoreMLModelLoader {

    /// ランタイム共通の MLModelConfiguration。
    /// シミュレータは MPSGraph/ANE バックエンドが無く .all だと Espresso 例外で推論が失敗するため
    /// CPU に固定する（実機は .all のまま ANE/GPU を活用）。
    static func makeConfiguration() -> MLModelConfiguration {
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #endif
        return config
    }

    /// バンドル同梱のコンパイル済みモデル（.mlmodelc）の URL。未同梱なら nil。
    static func bundledModelURL(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "mlmodelc")
    }

    /// 同梱モデルをロードし、結果を診断ログへ残す（実機で Mac なしに追えるように）。
    /// `subject` はログの主語（例 "CLIP image tower"）。ログ文言は
    /// 「\(subject) loaded in \(ms)ms (footprint=\(mb))」形式で従来と互換。
    static func loadBundledModel(named name: String, configuration: MLModelConfiguration,
                                 log: LogChannel, subject: String) -> MLModel? {
        guard let url = bundledModelURL(name) else {
            log.error("\(subject) not bundled")
            return nil
        }
        let started = Date()
        let model = try? MLModel(contentsOf: url, configuration: configuration)
        if model != nil {
            log.info("\(subject) \(loadStamp(since: started))")
        } else {
            log.error("\(subject) bundled but failed to load")
        }
        return model
    }

    /// ロード診断の共通サフィックス「loaded in \(ms)ms (footprint=\(mb))」。
    /// 複数リソースをまとめてロードするランタイム（VLM）はこれだけ共用する。
    static func loadStamp(since started: Date) -> String {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let mb = currentMemoryFootprintMB().map { String(format: "%.0fMB", $0) } ?? "?"
        return "loaded in \(ms)ms (footprint=\(mb))"
    }

    /// MLMultiArray → [Float]。NaN/Inf が混じったベクトルは壊れているので nil にする
    /// （コサイン類似が NaN 化し、検索・ゼロショット・顔クラスタが全滅するのを防ぐ）。
    static func finiteFloats(_ m: MLMultiArray) -> [Float]? {
        let result = (0..<m.count).map { Float(truncating: m[$0]) }
        return result.allSatisfy { $0.isFinite } ? result : nil
    }
}

/// ロード済み Core ML モデル 1 つ分のハンドル。modelDescription からの入出力名・画像制約の
/// 抽出と、画像 1 枚の推論（`MLFeatureValue(cgImage:constraint:)` → prediction → 有限 [Float]）
/// を共通化する。テキスト入力モデル（CLIP テキスト塔）も入出力名の抽出に使える
/// （その場合 `imageConstraint` は nil）。MLModel は推論スレッドセーフ。
struct CoreMLModelHandle: @unchecked Sendable {
    let model: MLModel
    let inputName: String
    let outputName: String
    let imageConstraint: MLImageConstraint?

    init(model: MLModel) {
        self.model = model
        let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? ""
        self.inputName = inputName
        self.outputName = model.modelDescription.outputDescriptionsByName.keys.first ?? ""
        self.imageConstraint = model.modelDescription.inputDescriptionsByName[inputName]?.imageConstraint
    }

    /// 画像 → 入力 FeatureProvider（リサイズ/画素変換はモデルの画像制約に従い自動）。
    /// バッチ推論（CLIP）や async 推論（VLM）はこれで組んだ provider を各自で流す。
    func imageProvider(for cgImage: CGImage) -> MLFeatureProvider? {
        guard let imageConstraint,
              let fv = try? MLFeatureValue(cgImage: cgImage, constraint: imageConstraint, options: nil)
        else { return nil }
        return try? MLDictionaryFeatureProvider(dictionary: [inputName: fv])
    }

    /// 画像 1 枚 → 出力ベクトル [Float]（NaN/Inf は壊れとみなし nil）。
    func predictVector(from cgImage: CGImage) -> [Float]? {
        guard let provider = imageProvider(for: cgImage),
              let out = try? model.prediction(from: provider)
        else { return nil }
        return vector(from: out)
    }

    /// 推論出力（バッチの 1 件を含む）→ 出力ベクトル [Float]（NaN/Inf は nil）。
    func vector(from features: MLFeatureProvider) -> [Float]? {
        guard let m = features.featureValue(for: outputName)?.multiArrayValue else { return nil }
        return CoreMLModelLoader.finiteFloats(m)
    }
}

/// NSLock ＋「.some(nil)=失敗を記録し再試行しない」センチネルの遅延ロード箱。
/// 重いモデルロードを初回利用まで遅らせつつ、失敗を毎回リトライしない（ログ洪水と無駄を防ぐ）。
final class LoadOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    /// nil = 未試行 / .some(nil) = ロード失敗（再試行しない） / .some(value) = ロード済み。
    private var state: Value??

    /// ロード済みならそれを、未試行なら `load()` を一度だけ実行して結果を返す。
    /// ロードはロック内で走る（多重ロード防止）。推論はロック外で行うこと。
    func get(_ load: () -> Value?) -> Value? {
        lock.lock(); defer { lock.unlock() }
        if let state { return state }
        let value = load()
        state = .some(value)
        return value
    }
}
