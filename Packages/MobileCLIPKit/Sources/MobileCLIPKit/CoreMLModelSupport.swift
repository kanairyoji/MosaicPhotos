import CoreGraphics
import CoreML
import Foundation
import MosaicSupport

/// Core ML ランタイム（MobileCLIP / FaceModel）が共有するプリミティブ。
/// - 設定（シミュレータ CPU 固定）・バンドル探索・ロード時間/フットプリントの診断ログ
/// - 単一入出力モデルの入出力名・画像制約の抽出と画像推論（`CoreMLModelHandle`）
/// - NSLock ＋失敗センチネルの遅延ロード（`LoadOnce`）
/// 各ランタイム固有の部分（CLIP のバッチ/テキスト塔等）は共通化しない。
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

    /// 「キャンセル済みなら重いモデルのロードを**始めない**」判定（ADR-95 追記）。
    ///
    /// 同梱モデルのロードは実機で 10〜35 秒かかり、いったん始めると中断できない。前面復帰で
    /// スキャンを止めた**直後に**始まると、その 10 秒ぶんがまるごと復帰の邪魔になる
    /// （実機 diagnostics-41: `faces: stopScan (foreground return)` の 1 秒後に
    /// `face model loaded in 10883ms`、同時刻にメインが 10.5 秒ブロック）。止めた意思を
    /// 「これから始める最も高価な操作」にも効かせる。
    ///
    /// ⚠️ 判定は **`LoadOnce` の外**で行う。中で nil を返すと `.some(nil)`＝「ロード失敗・再試行しない」
    /// として恒久的にキャッシュされ、その機能が二度と有効にならない。
    /// - Parameter isLoaded: 既にロード済みか。済みなら中断中でも使ってよい（ロードは発生しない）。
    static func skipLoadWhenCancelled(isLoaded: Bool, subject: String) -> Bool {
        guard !isLoaded, Task.isCancelled else { return false }
        Diagnostics.mark("model load skipped (cancelled) — \(subject)")
        return true
    }

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
        let epoch = ProcessSuspension.epoch
        let model = try? await MLModel.load(contentsOf: url, configuration: configuration)
        if model != nil {
            let stamp = loadStamp(since: started, epoch: epoch)
            log.info("\(subject) \(stamp)")
            Diagnostics.mark("model loaded \(subject) \(stamp)")
        } else {
            log.error("\(subject) bundled but failed to load")
            Diagnostics.mark("model FAILED \(subject)")
        }
        return model
    }

    /// ロード診断の共通サフィックス「loaded in \(ms)ms (footprint=\(mb))」。
    ///
    /// `epoch`（`ProcessSuspension.epoch`）を渡すと、**ロード中にプロセス中断があったサンプルは
    /// 数値を出さない**（ADR-80）。所要は壁時計 `Date()` 差分なので、アプリが背面へ落ちて中断された
    /// 時間まで含んでしまう。実際に「23,438ms」がバックグラウンド遷移をまたいで記録され、ロードが
    /// 遅いのか中断されただけなのか判別できなかった（過去にも同じ罠で 29 分のハングと誤読した事例あり）。
    static func loadStamp(since started: Date, epoch: Int? = nil) -> String {
        let mb = currentMemoryFootprintMB().map { String(format: "%.0fMB", $0) } ?? "?"
        if let epoch, ProcessSuspension.didSuspend(since: epoch) {
            return "loaded (spans suspend — duration unreliable) (footprint=\(mb))"
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
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
    /// バッチ推論（CLIP）はこれで組んだ provider を各自で流す。
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
/// 大きいモデルほど jetsam との競争で不利になる。
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

    /// ロード済みモデルを解放する（1-d・メモリ圧迫時）。次回 `get` で再ロードされる。
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

/// **同梱モデルを抱えたまま眠らない**（ADR-223）。
///
/// ⚠️ 実機ログ diagnostics-88: 夜の処理枠で CLIP テキスト塔（505MB）→ 顔モデル（650MB）と
/// 読み込み、窓が終わってもそのまま常駐していた。アプリはその後 30 分眠るので、
/// **誰も使っていない 300〜500MB を抱えたまま jetsam の候補になっていた**
/// （背面のアプリは footprint の大きい順に落とされる）。
///
/// 窓の終わりに手放し、次の窓で読み直す（7〜17 秒）。窓は 30 分おきなので割に合う。
///
/// ⚠️ ADR-223 は「**前面では手放さない**」と決めたが、それは**窓の終わりに手放すか**という
/// 問いへの答えで、「前面で放置され続けた場合」は見ていなかった（常駐メモリの棚卸し）。
/// 実際には検索を 1 回すればテキスト塔（実測 footprint 505MB）が載り、その後は
/// critical 圧迫か「背面化 + 窓の終了」まで載りっぱなしになる。電源に繋がない端末では
/// 事実上ずっと常駐する。⚠️ `ModelIdlePolicy` はそこだけを埋める——**一定時間まったく
/// 使われず、解析も走っていない**ときに限り、前面でも手放す。
public enum PerceptionModels {

    /// **顔モデルだけ**手放す（顔スキャンが 1 巡終わった時点・ADR-223）。
    ///
    /// このあと窓はタグ付け → CLIP 埋め込みへ進む。顔モデル（約 300MB）を持ち越すと
    /// CLIP の塔と二重に抱えることになり、窓のピークが 650MB になる。
    /// ⚠️ 残作業があるなら手放さない（すぐ読み直すことになる）。前面でも手放さない。
    @discardableResult
    @MainActor
    public static func releaseFaceModelIfDone(backlog: Int, reason: String) -> Bool {
        guard backlog == 0, BackgroundYield.scenePhase != .active else { return false }
        guard FaceModelRuntime.shared.releaseForIdle(reason: reason) else { return false }
        Diagnostics.mark("models released (\(reason))")
        return true
    }

    /// 窓が終わったので手放す。前面のときは何もしない。
    /// - Returns: 実際に手放したか（ログ用）。
    @discardableResult
    @MainActor
    public static func releaseForIdle(reason: String) -> Bool {
        guard BackgroundYield.scenePhase != .active else { return false }
        return releaseNow(reason: reason)
    }

    // MARK: - 前面でも、使われなくなったら手放す（常駐メモリの棚卸し）

    /// 推論が走ったことを記録する。**`MLInferenceGate` を通る経路すべてから呼ぶ**
    /// ——呼び忘れると「使っていない」と誤判定して、使用中のモデルを手放しかねない。
    ///
    /// ⚠️ 記録するのは推論の**開始時**（ゲートに入る前）。終了時にすると、ゲートで待っている
    /// 長い推論が「使っていない」と見えて、走っている最中に取り上げられ得る。
    static func noteInference(now: Date = Date()) {
        ModelIdleTracker.shared.note(now: now)
    }

    /// **前面/背面を問わず**手放す（判断は呼び出し側が済ませている前提）。
    @discardableResult
    @MainActor
    static func releaseNow(reason: String) -> Bool {
        let clip = MobileCLIPRuntime.shared.releaseForIdle()
        let face = FaceModelRuntime.shared.releaseForIdle(reason: reason)
        guard clip || face else { return false }
        Diagnostics.mark("models released (\(reason))")
        return true
    }

    /// 一定時間まったく使われていなければ手放す（前面でも）。
    ///
    /// ⚠️ 判定と「記録を消す」は `ModelIdleTracker` の中で**ひと続き**に行う。
    /// ここで「判定 → 手放す → 消す」と 3 段に分けると、その途中に推論スレッドからの
    /// `noteInference()` が割り込み、**たった今使い始めた印を消してしまう**
    /// （そして走り始めた推論からモデルを取り上げる）。
    ///
    /// - Parameter analysisRunning: 解析（窓・ブースト・埋め込み・顔スキャン）が走っているか。
    ///   走っている最中に取り上げると、その場で 10〜35 秒の再ロードが始まり、
    ///   ANE ゲートの中なのでほかの推論も止まる。
    /// - Returns: 実際に手放したか。
    @discardableResult
    @MainActor
    public static func releaseIfIdle(now: Date = Date(),
                                     idleSeconds: TimeInterval = ModelIdlePolicy.idleSeconds,
                                     analysisRunning: Bool) -> Bool {
        guard ModelIdleTracker.shared.consumeIfIdle(now: now, idleSeconds: idleSeconds,
                                                    analysisRunning: analysisRunning)
        else { return false }
        return releaseNow(reason: "idle \(Int(idleSeconds))s")
    }
}
