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
        #else
        // 提案4: 実機は **ANE＋CPU（GPU 回避）** にする。GPU は UI 合成（Metal）と食い合うため、
        //   前景で走る推論（検索の CLIP テキスト埋め込み等）が UI 描画とコアを奪い合うのを避ける。
        //   同梱モデルは INT8/fp16 で ANE 向けに変換済み＝ANE 主体でも速度低下は小さい見込み。
        //   （夜間の重い処理は電源＋ロック中のみ＝そこでは GPU 空きだが、前景の滑らかさを優先）。
        config.computeUnits = .cpuAndNeuralEngine
        #endif
        return config
    }

    /// バンドル同梱のコンパイル済みモデル（.mlmodelc）の URL。未同梱なら nil。
    static func bundledModelURL(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "mlmodelc")
    }

    /// ⚠️ 旧 `serializedLoad`（グローバル NSLock でモデルロードを直列化・1-c）は**撤去**した。
    /// 実機で 1 つのロードが詰まると facenet/CLIP 埋め込みが**全て永久ブロック**され、顔認識が動かなく
    /// なる事例が出たため（ADR-70 導入後に発生。導入前＝並列ロードは正常に動いていた）。ロード時の
    /// 一時メモリ増よりも、確実にロード完了することを優先する（＝並列ロードに戻す）。

    /// 同梱モデルをロードし、結果を診断ログへ残す（実機で Mac なしに追えるように）。
    /// `subject` はログの主語（例 "CLIP image tower"）。開始時にも `loading…` を残し、ロードが詰まって
    /// いる場合に「開始したが完了しない」と分かるようにする（診断）。
    ///
    /// ⚠️ **async ロード必須**。同期 `MLModel(contentsOf:)` は CLIP 画像塔で実機 16〜35 秒かかり、
    /// その間 Swift 並行の協調スレッドを 1 本まるごとブロックしていた（`LoadOnce` の NSLock 内で実行して
    /// いたため）。`MLModel.load` なら待ちがサスペンドになり、スレッドは他の仕事に回せる。
    static func loadBundledModel(named name: String, configuration: MLModelConfiguration,
                                 log: LogChannel, subject: String) async -> MLModel? {
        guard let url = bundledModelURL(name) else {
            log.error("\(subject) not bundled")
            return nil
        }
        Diagnostics.mark("model loading… \(subject)")
        let started = Date()
        let model = try? await MLModel.load(contentsOf: url, configuration: configuration)
        if model != nil {
            log.info("\(subject) \(loadStamp(since: started))")
            Diagnostics.mark("model loaded \(subject) \(loadStamp(since: started))")
        } else {
            log.error("\(subject) bundled but failed to load")
            Diagnostics.mark("model FAILED \(subject)")
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
    ///
    /// 添字アクセス（`m[i]`）は 1 要素ごとに `NSNumber` を作るため、512 次元 ×（顔数 × 3 クロップ）
    /// ぶんの箱詰めが積み上がる。連続領域なら型付きバッファで一括に読む。
    /// ストライドが連続でない場合と未知の dataType は、従来の添字アクセスへフォールバックする
    /// （速度より正しさを優先。連続でないのに一括読みすると**静かに順序が壊れる**）。
    static func finiteFloats(_ m: MLMultiArray) -> [Float]? {
        let result: [Float]
        if isContiguous(m), m.dataType == .float32 {
            result = m.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
        } else if isContiguous(m), m.dataType == .float16 {
            result = m.withUnsafeBufferPointer(ofType: Float16.self) { $0.map { Float($0) } }
        } else {
            result = (0..<m.count).map { Float(truncating: m[$0]) }
        }
        return result.allSatisfy { $0.isFinite } ? result : nil
    }

    /// 末尾次元から順にストライドが積形になっているか（＝row-major で隙間なく並んでいるか）。
    private static func isContiguous(_ m: MLMultiArray) -> Bool {
        var expected = 1
        for axis in stride(from: m.shape.count - 1, through: 0, by: -1) {
            if m.strides[axis].intValue != expected { return false }
            expected *= m.shape[axis].intValue
        }
        return true
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
        let inputs = model.modelDescription.inputDescriptionsByName
        let outputs = model.modelDescription.outputDescriptionsByName
        // ⚠️ `Dictionary.keys.first` は**順序不定**。同梱モデルはすべて単一入出力なので今は当たらないが、
        // モデルを差し替えて入出力が増えたとき、実行ごとに違う名前を掴んで静かに壊れる。
        // 名前でソートして決定的に選び、複数あった場合は診断ログに残して気づけるようにする。
        let inputName = inputs.keys.sorted().first ?? ""
        self.inputName = inputName
        self.outputName = outputs.keys.sorted().first ?? ""
        self.imageConstraint = inputs[inputName]?.imageConstraint
        if inputs.count > 1 || outputs.count > 1 {
            Diagnostics.mark("model has multiple I/O — using input=\(inputName) output=\(outputName) "
                             + "(inputs=\(inputs.count) outputs=\(outputs.count))")
        }
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

/// 「.some(nil)=失敗を記録し再試行しない」センチネル付きの遅延ロード箱。
/// 重いモデルロードを初回利用まで遅らせつつ、失敗を毎回リトライしない（ログ洪水と無駄を防ぐ）。
///
/// ## なぜ actor ではなく NSLock なのか（ADR-74 追補）
/// ロード自体は **async**（`MLModel.load`）にする必要がある——同期 `MLModel(contentsOf:)` は CLIP
/// 画像塔で実機 16〜35 秒かかり、その間ロックを握ったまま協調スレッドを 1 本潰していた。
/// 一方で **`reset()` / `isLoaded` は同期でなければならない**。メモリ圧迫ハンドラ
/// （`MemoryPressureMonitor.handle` はハンドラを同期的に呼ぶ）から呼ばれるため、actor にすると
/// `Task { await box.reset() }` となり「critical 圧迫を受けたのに解放は後回し」になる。
/// VLM は 877MB あり、jetsam との競争で不利になる。
/// そこで **状態は NSLock、ロードは Task で await** のハイブリッドにする。
///
/// `@unchecked Sendable` の根拠（不変条件）: 可変状態はすべて private・アクセスは必ず `lock` 経由・
/// **ロックを `await` 越しに保持しない**（`get` は必ず unlock してから await する）・
/// 可変参照を外へ出さない。
final class LoadOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    /// nil = 未試行 / .some(nil) = ロード失敗（再試行しない） / .some(value) = ロード済み。
    private var state: Value??
    /// 実行中のロード（後続の `get` はこれに合流する＝二重ロード防止）。
    private var inFlight: Task<Value?, Never>?
    /// `reset()` の世代。ロード中に解放が割り込んだかの判定に使う（`Task` は値型で同一性比較できない）。
    private var generation = 0

    /// ロード済みならそれを、未試行なら `load()` を一度だけ実行して結果を返す。
    func get(_ load: @Sendable @escaping () async -> Value?) async -> Value? {
        lock.lock()
        if let state {
            lock.unlock()
            return state
        }
        if let inFlight {
            lock.unlock()                 // ← await の前に必ず手放す
            return await inFlight.value
        }
        let startedAt = generation
        let task = Task { await load() }
        inFlight = task
        lock.unlock()                     // ← await の前に必ず手放す

        let value = await task.value

        lock.lock()
        // ロード中に reset()（圧迫解放）が割り込んでいたら、この結果は確定させない
        // ——確定させると「解放したのに次の get でロード済みが返る」ことになる。
        if generation == startedAt {
            state = .some(value)
            inFlight = nil
        }
        lock.unlock()
        return value
    }

    /// ロード済みモデルを解放する（1-d・メモリ圧迫時や重い VLM の使用後）。次回 `get` で再ロードされる。
    /// 失敗センチネルも消すので、以前失敗していても再試行する。
    /// **同期**であることが重要（メモリ圧迫ハンドラから即時に効かせるため）。
    func reset() {
        lock.lock()
        state = nil
        inFlight = nil
        generation &+= 1
        lock.unlock()
    }

    /// 現在ロード済みか（解放判断用・ロードは起こさない）。
    var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .some(.some) = state { return true }
        return false
    }
}
