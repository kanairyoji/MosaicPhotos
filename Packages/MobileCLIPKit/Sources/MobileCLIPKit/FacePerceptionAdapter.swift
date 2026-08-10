import AutoAlbumCore
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
import CoreImage
import Foundation
import MosaicSupport
import Photos
import Vision

/// `FacePerceptionProvider` の実体。Vision で顔を検出し、顔を切り抜いて同梱 Core ML 顔モデルで
/// identity 埋め込みを得る。端末写真（"L-…"）は 640px で、クラウド（"C-…"）は `cloudImage` 経由の
/// キャッシュ済みサムネ（w128h128・追加DL無し）で処理する。クラウドは低解像度なので**大きく写った顔
/// 中心**（集合写真・引きの顔は苦手）＝品質は割り切り（ADR: option B）。
/// 顔モデル未同梱なら `isAvailable == false`／空を返し、ピープルは無効になるだけ。
public struct FacePerceptionAdapter: FacePerceptionProvider {
    /// クラウド path → CGImage（Dropbox のキャッシュ済み 128px サムネ）。nil なら端末写真のみ対象。
    let cloudImage: (@Sendable (String) async -> CGImage?)?
    /// クラウド path 群のサムネを**一括で先行取得**するヒント（ADR-83・即座に返る）。
    let warmCloud: (@Sendable ([String]) -> Void)?
    /// **顔解析用 1024px** のバッチ取得（ADR-90）。表示用 256px では顔が小さすぎるため、
    /// 顔スキャンだけはこちらを使う。取得結果はディスクに残さず `analysisCache` で使い捨てる。
    let cloudAnalysisImages: (@Sendable ([String]) async -> [String: Data])?
    /// 1 バッチぶんの 1024px 画像置き場（使ったら破棄）。
    private let analysisCache = CloudAnalysisImageCache()

    public init(cloudImage: (@Sendable (String) async -> CGImage?)? = nil,
                warmCloud: (@Sendable ([String]) -> Void)? = nil,
                cloudAnalysisImages: (@Sendable ([String]) async -> [String: Data])? = nil) {
        self.cloudImage = cloudImage
        self.warmCloud = warmCloud
        self.cloudAnalysisImages = cloudAnalysisImages
    }

    /// バッチの素材を先に取りに行く（ADR-83）。顔解析は **1024px をバッチ取得**して
    /// `analysisCache` に積む（ADR-90）。1 枚ずつ取ると 1 枚 0.9 秒＝62,744 枚で 17 時間になるため、
    /// 表示用と同じ 25 枚/リクエストのバッチに相乗りする。
    public func warmUp(refKeys: [String]) {
        guard let cloudAnalysisImages else {
            warmCloudPaths(refKeys, using: warmCloud)   // 解析取得が無い構成では従来どおり
            return
        }
        let paths = refKeys.compactMap { PhotoRef.decode($0)?.cloudPath }
        guard !paths.isEmpty else { return }
        let cache = analysisCache
        Task(priority: .utility) {
            let fetched = await cloudAnalysisImages(paths)
            for (path, data) in fetched {
                guard let image = UIImage(data: data),
                      let cg = orientationNormalizedCGImage(image) else { continue }
                await cache.store(cg, for: path)
            }
        }
    }

    /// 同梱判定のみ（**ロードを起こさない**・1-a）。実ロードは初回 `detectFaces`→`embed` まで遅延。
    public var isAvailable: Bool { FaceModel.modelBundled }

    public func detectFaces(refKeys: [String]) async -> [String: [DetectedFaceSignal]] {
        var result: [String: [DetectedFaceSignal]] = [:]
        var loaded = 0, nilImage = 0, rawFaces = 0, embedded = 0, visionErr = 0
        var lastError: String?
        // 計測(b/c 判断用): 画像ロード ms と 推論(Vision 検出＋facenet 埋め込み) ms を分けて集計する。
        // ANE 実機で「1 枚 ~1s」のうちロードと推論のどちらが支配的かを次回ログで可視化する
        // （ロード支配ならプリフェッチ(c)、Vision 支配なら検出解像度(b) の効果が見込める）。
        // ⚠️ 所要は**プロセス中断（suspend）を跨いだら計上しない**。`CFAbsoluteTimeGetCurrent` は
        // 壁時計なので suspend 中も進み、1 枚が 29 分に化けて合計を壊す（実機ログ diagnostics-20 で
        // load 合計 1,868,367ms のうち 1,769,333ms が単一の外れ値だった。中央値は 81ms）。
        var loadMs = 0.0, inferMs = 0.0, discarded = 0
        for refKey in refKeys {
            guard let ref = PhotoRef.decode(refKey) else { continue }
            let source: CGImage?
            let suspensionEpoch = ProcessSuspension.epoch
            let tLoad = CFAbsoluteTimeGetCurrent()
            if let localID = ref.localIdentifier {
                // 端末写真: 1024px（ADR-51・旧 640px）。集合写真の端の小さい顔も埋め込みに
                // 足る解像度を確保する。メモリ増（約2.6倍/枚）は夜間・1枚ずつ処理＋
                // メモリ圧迫ゲート（shouldPause）で吸収する。
                source = await loadLocalCGImage(localID, maxPixel: 1024)
            } else if let path = ref.cloudPath {
                // クラウド: 顔解析は **1024px**（ADR-90）。表示用 256px では顔が小さすぎて
                // 埋め込みに使えなかった（実測 diag-35: 到達率 3.8% → 1024px で 29.7%）。
                // `warmUp` がバッチ取得した分をここで 1 枚ずつ受け取り、取り出したら破棄する。
                // 取りこぼし（先読み前・バッチ失敗）は単発取得へフォールバックし、
                // それも無ければ従来の表示用サムネで代替する（何も出ないよりはよい）。
                if let warmed = await analysisCache.take(path) {
                    source = warmed
                } else if let cloudAnalysisImages,
                          let data = await cloudAnalysisImages([path])[path],
                          let image = UIImage(data: data) {
                    source = orientationNormalizedCGImage(image)
                } else if cloudAnalysisImages != nil {
                    // ⚠️ 1024px が取れないときは **256px へ落とさない**（ADR-92）。
                    // 落とすと「顔が採れないまま**スキャン済みとして記録**」され、版を上げるまで
                    // 二度と見直されない。取得できない理由は一時的（閲覧中で譲った・回線・
                    // バッチ失敗）なことが多いので、**この写真は今回見送る**（下流が未記録にする）。
                    source = nil
                } else if let cloudImage {
                    source = await cloudImage(path)   // 解析取得を注入しない構成（テスト等）
                } else {
                    source = nil
                }
            } else {
                source = nil
            }
            let loadElapsed = (CFAbsoluteTimeGetCurrent() - tLoad) * 1000
            guard let cg = source else { nilImage += 1; continue }
            loaded += 1
            // ⚠️ ANE 直列化ゲートは `detect` の内側（Vision perform／facenet 推論の各段）で取る。
            // 上の画像ロードはゲート外＝ロード中に他の推論（CLIP 埋め込み・Vision タグ）を止めない。
            // 以前は呼び出し側の FaceTagger が detectFaces 全体を包んでおり、ロード時間ぶんも
            // ゲートを占有していた（load/infer の実測内訳はそのための計測）。
            let tInfer = CFAbsoluteTimeGetCurrent()
            var (raw, signals, error) = await detect(in: cg, isCloud: ref.localIdentifier == nil)
            let inferElapsed = (CFAbsoluteTimeGetCurrent() - tInfer) * 1000
            // 中断を跨いだ 1 枚は所要を捨てる（件数だけ数えてログに出す）。
            if ProcessSuspension.didSuspend(since: suspensionEpoch) {
                discarded += 1
            } else {
                loadMs += loadElapsed
                inferMs += inferElapsed
            }
            // ADR-61: 撮影日を載せる（時期グループ分割用）。ローカルは PHAsset.creationDate。
            // クラウドは seam 未整備のため当面 nil（personReps は nil を最古扱いで動く）。
            if let localID = ref.localIdentifier, let date = Self.creationDate(localID) {
                signals = signals.map { DetectedFaceSignal(
                    boundingBox: $0.boundingBox, embedding: $0.embedding, quality: $0.quality,
                    hasSmile: $0.hasSmile, captureDate: date) }
            }
            if let error { visionErr += 1; lastError = error }
            rawFaces += raw
            embedded += signals.count
            // ⚠️ 中断された 1 枚は**結果に載せない**（ADR-92 と同じ理由・ADR-95 追記）。
            //    載せると FaceTagger が「走査済み」として記録してしまい、埋め込みが取れていない
            //    写真が次の窓で二度と拾われなくなる（版を上げるまで顔が失われる）。中断時は
            //    モデルのロードを見送るので `signals` が空になり得る＝まさにその状態になる。
            if Task.isCancelled { break }
            result[refKey] = signals
        }
        // 切り分け用: 画像ロード成否・Vision 生検出数・埋め込み成功数・Vision エラー＋所要内訳(ms)。
        Diagnostics.mark("faces.detect: loaded=\(loaded) nil=\(nilImage) rawFaces=\(rawFaces) "
                         + "embedded=\(embedded) visionErr=\(visionErr) "
                         + "load=\(Int(loadMs))ms infer=\(Int(inferMs))ms"
                         + (discarded > 0 ? " suspended=\(discarded)" : "")
                         + "\(lastError.map { " (\($0))" } ?? "")")
        return result
    }

    /// 1 顔分の観測（矩形・品質・向き・目閉じ・笑顔・両目中心）。
    private struct FaceObservation {
        var box: CGRect
        var quality: Float
        /// 顔検出そのものの信頼度（VNFaceObservation.confidence・フォールバックは 1）。
        var confidence: Float = 1
        var yaw: Float?
        var roll: Float?
        var eyesClosed: Bool?
        var hasSmile: Bool?
        /// 両目の中心（ピクセル・原点左下）。アライメント切り抜き（ADR-51）に使う。
        var eyeLeft: CGPoint?
        var eyeRight: CGPoint?
        /// 鼻先・口角（ピクセル・原点左下）。ArcFace 5 点整列（ADR-70）に使う。
        var nose: CGPoint?
        var mouthLeft: CGPoint?
        var mouthRight: CGPoint?
    }

    /// パイプライン版（face_config.json が宣言・無ければ facenet 世代の 4）。
    public var pipelineVersion: Int { FaceModelConfig.bundled?.pipelineVersion ?? 4 }

    /// 類似度スケール依存の定数一式（face_config.json の tuning が宣言・ADR-70）。
    public var tuning: FaceTuning { FaceTuning.named(FaceModelConfig.bundled?.tuning) }

    /// 戻り値 `.raw` は検出した顔数（フィルタ前）、`.signals` は埋め込みまで成功した顔、
    /// `.error` は Vision が使えず CIDetector にフォールバックした場合のメッセージ（切り分け用）。
    /// face-info-expansion: 顔向き（yaw/roll）・目閉じ・笑顔を追加取得し、
    /// 品質を `FaceQualityGate` で一元調整する（横顔はフロア未満＝クラスタへ入れない）。
    private func detect(in cg: CGImage, isCloud: Bool) async -> (raw: Int, signals: [DetectedFaceSignal], error: String?) {
        let (analyses, error) = await analyzeFaces(in: cg, isCloud: isCloud)
        // 棄却の内訳を本番経路のまま数える（ADR-68 追補2）。しきい値を触る前に、
        // 「どのゲートがどれだけ落としているか」を実機で確かめられるようにする。
        for a in analyses {
            FaceDetectionStats.record(
                reason: a.report.rejectReason,
                // 品質フロア（クラスタ不参加＝第2パス送り）は FaceStore 側の定数と同値。
                belowQualityFloor: a.signal != nil && a.report.adjustedQuality < 0.40)
        }
        return (analyses.count, analyses.compactMap(\.signal), error)
    }

    /// 顔ゲートの判定レポート（検証ハーネス・Developer 用の公開型）。
    /// 「どの顔が・どの理由で・どの数値で」通過/棄却されたかを 1 顔ずつ返す。
    public struct FaceGateReport: Sendable {
        public let pixelSize: CGSize
        public let confidence: Float
        public let rawQuality: Float
        public let adjustedQuality: Float
        public let blurVariance: Float?
        public let meanLuma: Float?
        public let yaw: Float?
        public let roll: Float?
        public let accepted: Bool
        /// 棄却理由: size-ratio / size-pixels / low-confidence / crop-failed / not-a-face /
        /// embed-failed。通過は nil（adjustedQuality がフロア未満なら「記録のみ・クラスタ不参加」）。
        public let rejectReason: String?
    }

    /// 画像 1 枚をゲート込みで解析してレポートを返す（**検証ハーネス用**・埋め込み含む本番同一経路）。
    /// 端末へ入れて大量スキャンせずとも、問題写真をフォルダに置いてしきい値を素早く調整できる。
    public func debugAnalyze(_ cg: CGImage, isCloud: Bool = false) async -> [FaceGateReport] {
        await analyzeFaces(in: cg, isCloud: isCloud).analyses.map(\.report)
    }

    /// 精度計測ハーネス用: レポート＋採用顔の埋め込み（fp32・正規化済み）を返す。
    /// 経路は本番（detect）と完全に同一（マルチクロップ平均含む）。
    public func debugAnalyzeWithEmbeddings(_ cg: CGImage, isCloud: Bool = false) async
        -> [(report: FaceGateReport, embedding: [Float]?, quality: Float?)] {
        await analyzeFaces(in: cg, isCloud: isCloud).analyses.map { analysis in
            let vec = analysis.signal.flatMap { ClipMath.decodeHalf($0.embedding) }
            return (analysis.report, vec, analysis.signal?.quality)
        }
    }

    private struct FaceAnalysis {
        var report: FaceGateReport
        var signal: DetectedFaceSignal?
    }

    /// 1 枚分の顔解析（品質ゲート＋マルチクロップ埋め込み）。
    /// 候補B: **全顔の全クロップ（アライメント/反転/bbox）を平坦配列に集めて 1 回でバッチ推論**する。
    /// クロップ内容・平均は従来どおり＝精度不変。顔ごと・クロップごとの単発推論オーバーヘッドを償却する。
    ///
    /// ANE 直列化ゲートは**この関数の内側で段ごと**に取る（顔観測／クロップ再検証／埋め込み）。
    /// 1 枚まるごとを 1 回のゲートで包むと、顔の多い写真で数秒間ゲートを占有して他の解析が飢える。
    /// 段の切れ目でゲートを手放しても、ANE を同時に使わないという不変条件は保たれる。
    private func analyzeFaces(in cg: CGImage, isCloud: Bool) async -> (analyses: [FaceAnalysis], error: String?) {
        let (faces, error) = await faceObservations(in: cg)   // 正規化(原点左下)の矩形＋品質＋向き＋属性

        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        // 小さすぎる顔は埋め込み精度が低いので除外（クラウドは低解像度サムネのため大きい顔のみ）。
        let minSide = FaceQualityGate.minFaceSide(isCloud: isCloud)

        /// 顔ごとの中間状態（埋め込み前）。`cropRange` は flatCrops への索引範囲（nil＝棄却で埋め込み無し）。
        struct Row {
            var pixelSize: CGSize
            var confidence: Float
            var rawQuality: Float
            var adjusted: Float
            var blur: Float?
            var luma: Float?
            var yaw: Float?
            var roll: Float?
            var box: CGRect
            var hasSmile: Bool?
            var reason: String?
            var cropRange: Range<Int>?
        }
        var rows: [Row] = []
        var flatCrops: [CGImage] = []

        // Pass 1: 品質ゲート・クロップ生成。埋め込み対象のクロップを平坦配列へ集める。
        for face in faces {
            let pixelBox = CGRect(x: face.box.origin.x * width, y: face.box.origin.y * height,
                                  width: face.box.width * width, height: face.box.height * height)
            var row = Row(pixelSize: pixelBox.size, confidence: face.confidence,
                          rawQuality: face.quality, adjusted: face.quality, blur: nil, luma: nil,
                          yaw: face.yaw, roll: face.roll, box: face.box, hasSmile: face.hasSmile,
                          reason: nil, cropRange: nil)

            if face.box.width < minSide || face.box.height < minSide {
                row.reason = "size-ratio"
            } else if pixelBox.width < FaceQualityGate.minFacePixels
                        || pixelBox.height < FaceQualityGate.minFacePixels {
                row.reason = "size-pixels"
            } else if face.confidence < FaceQualityGate.minDetectionConfidence {
                row.reason = "low-confidence"
            } else {
                // ADR-70: ArcFace 系モデル（face_config.json が arcface5 を宣言）は 5 点整列を最優先。
                // 5 点が揃わない・退化しているときは従来の両目整列 → bbox へ段階フォールバック。
                let arcAligned: CGImage? = {
                    guard FaceModelConfig.bundled?.usesArcFaceAlignment == true,
                          let l = face.eyeLeft, let r = face.eyeRight, let n = face.nose,
                          let ml = face.mouthLeft, let mr = face.mouthRight,
                          let transform = FaceAlignment.arcFaceTransform(points: .init(
                              leftEye: l, rightEye: r, nose: n, mouthLeft: ml, mouthRight: mr))
                    else { return nil }
                    return arcFaceCrop(cg, transform: transform)
                }()
                // ADR-51: 両目ランドマークがあればアライメント切り抜き（無ければ bbox へフォールバック）。
                let aligned: CGImage? = arcAligned ?? {
                    guard let l = face.eyeLeft, let r = face.eyeRight,
                          let plan = FaceAlignment.plan(leftEye: l, rightEye: r, pixelBox: pixelBox)
                    else { return nil }
                    return alignedCrop(cg, plan: plan)
                }()
                let bboxCrop = cropFace(cg, normalizedBox: face.box, width: width, height: height)
                let crop = aligned ?? bboxCrop
                if let crop {
                    if !(await verifyFaceInCrop(crop)) {
                        row.reason = "not-a-face"   // ADR-53: 二段検出
                    } else {
                        let metrics = Self.faceMetrics(crop)
                        row.blur = metrics?.blurVariance
                        row.luma = metrics?.meanLuma
                        row.adjusted = FaceQualityGate.adjustedQuality(
                            quality: face.quality, yaw: face.yaw, roll: face.roll,
                            eyesClosed: face.eyesClosed,
                            blurVariance: metrics?.blurVariance, meanLuma: metrics?.meanLuma)
                        // マルチクロップ（ADR-54）: 主＋水平反転＋（アライメント時は）bbox。
                        var crops: [CGImage] = [crop]
                        if let flipped = Self.horizontallyFlipped(crop) { crops.append(flipped) }
                        if aligned != nil, let bboxCrop { crops.append(bboxCrop) }
                        let start = flatCrops.count
                        flatCrops.append(contentsOf: crops)
                        row.cropRange = start..<flatCrops.count
                    }
                } else {
                    row.reason = "crop-failed"
                }
            }
            rows.append(row)
        }

        // Pass 2: 全クロップを 1 回でバッチ推論（顔・クロップを跨いで償却）。ゲートは runtime の内側。
        let vectors = await FaceModelRuntime.shared.embed(flatCrops)

        // Pass 3: 顔ごとに自分のクロップの埋め込みを平均→再正規化して signal を組む。
        var out: [FaceAnalysis] = []
        for row in rows {
            var signal: DetectedFaceSignal?
            var reason = row.reason
            if let range = row.cropRange {
                let v = range.compactMap { vectors[$0] }
                if let averaged = FaceClustering.averagedEmbedding(v) {
                    signal = DetectedFaceSignal(
                        boundingBox: row.box,
                        embedding: ClipMath.encodeHalf(averaged),
                        quality: row.adjusted,
                        hasSmile: row.hasSmile)
                } else {
                    reason = "embed-failed"
                }
            }
            out.append(FaceAnalysis(
                report: FaceGateReport(pixelSize: row.pixelSize,
                                       confidence: row.confidence,
                                       rawQuality: row.rawQuality,
                                       adjustedQuality: row.adjusted,
                                       blurVariance: row.blur,
                                       meanLuma: row.luma,
                                       yaw: row.yaw, roll: row.roll,
                                       accepted: signal != nil,
                                       rejectReason: reason),
                signal: signal))
        }
        return (out, error)
    }

    /// PHAsset の撮影日（ADR-61・時期グループ分割用）。取得不可は nil。
    private static func creationDate(_ localIdentifier: String) -> Date? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject?.creationDate
    }

    /// 水平反転（マルチクロップ埋め込み用）。
    private static func horizontallyFlipped(_ cg: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(cg.width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return ctx.makeImage()
    }

    /// クロップ再検証（ADR-53）: 顔中心に切り抜いた画像内でもう一度顔検出し、
    /// 実際に顔があるか確認する（模様・物体の誤検出はここで落ちる）。クロップは顔中心なので
    /// 検出顔がクロップ幅の一定割合以上を占めることを要求する。Vision が使えない環境
    ///（シミュレータの一部）では判定不能＝棄却しない。
    private func verifyFaceInCrop(_ crop: CGImage) async -> Bool {
        await MLInferenceGate.shared.run {
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: crop, options: [:])
            guard (try? handler.perform([request])) != nil else { return true }
            guard let results = request.results, !results.isEmpty else { return false }
            return results.contains { $0.boundingBox.width >= FaceQualityGate.cropVerifyMinSide }
        }
    }

    /// 顔観測（Vision 正規化・原点左下）を返す。**1 回の perform** で品質＋ランドマークを取得し、
    /// 失敗（シミュレータの "Could not create inference context" 等）なら顔矩形のみ→CIDetector に
    /// フォールバック（品質は 1＝中立。実機はほぼ常に品質つきで取れる）。
    /// 笑顔は CIDetector（CIDetectorSmile）を 1 パス追加して bbox で照合する。
    private func faceObservations(in cg: CGImage) async -> (faces: [FaceObservation], error: String?) {
        await MLInferenceGate.shared.run { self.unsafeFaceObservations(in: cg) }
    }

    /// **計測用**: 品質ゲートを通さない生の検出結果を返す（ADR-89）。
    /// 歩留まり計測は「どのゲートで何が落ちているか」を知るのが目的なので、
    /// 本番と**同じ Vision 設定**で検出だけ行い、採否は呼び出し側（`FaceYieldMeasurement`）が
    /// サイズ別に算術で判定する。埋め込みは作らない（速い）。
    public func observeFacesForMeasurement(in cg: CGImage) async -> [FaceYieldMeasurement.FaceObservation] {
        let (faces, _) = await faceObservations(in: cg)
        return faces.map {
            FaceYieldMeasurement.FaceObservation(
                normalizedShortSide: min($0.box.width, $0.box.height),
                confidence: $0.confidence,
                quality: $0.quality)
        }
    }

    /// ゲート保持済み前提の本体（入れ子で `run` を呼ばないこと）。
    private func unsafeFaceObservations(in cg: CGImage) -> (faces: [FaceObservation], error: String?) {
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        do {
            try handler.perform([qualityRequest, landmarksRequest])
            let obs = qualityRequest.results ?? []
            guard !obs.isEmpty else { return ([], nil) }   // 顔なし（エラーではない）
            let landmarks = landmarksRequest.results ?? []
            let smiles = ciSmileBoxes(in: cg)
            let imageSize = CGSize(width: cg.width, height: cg.height)
            let faces = obs.map { o -> FaceObservation in
                // ランドマーク観測は bbox の重なり（IoU 最大）で対応づける。
                let lm = Self.bestMatch(for: o.boundingBox, in: landmarks.map(\.boundingBox))
                    .map { landmarks[$0] }
                let yaw = (lm?.yaw ?? o.yaw)?.floatValue
                let roll = (lm?.roll ?? o.roll)?.floatValue
                let eyesClosed = lm?.landmarks.flatMap { Self.eyesClosed($0) }
                let smile = Self.bestMatch(for: o.boundingBox, in: smiles.map(\.box))
                    .map { smiles[$0].hasSmile }
                return FaceObservation(box: o.boundingBox,
                                       quality: o.faceCaptureQuality ?? 1,
                                       confidence: o.confidence,
                                       yaw: yaw, roll: roll,
                                       eyesClosed: eyesClosed, hasSmile: smile,
                                       eyeLeft: Self.regionCenter(lm?.landmarks?.leftEye, imageSize: imageSize),
                                       eyeRight: Self.regionCenter(lm?.landmarks?.rightEye, imageSize: imageSize),
                                       nose: Self.regionCenter(lm?.landmarks?.nose, imageSize: imageSize),
                                       mouthLeft: Self.lipCorner(lm?.landmarks?.outerLips, imageSize: imageSize, left: true),
                                       mouthRight: Self.lipCorner(lm?.landmarks?.outerLips, imageSize: imageSize, left: false))
            }
            return (faces, nil)
        } catch {
            // フォールバック 1: 矩形のみ（品質は取れないので 1）。
            let rectRequest = VNDetectFaceRectanglesRequest()
            if (try? handler.perform([rectRequest])) != nil, let rects = rectRequest.results {
                return (rects.map {
                    FaceObservation(box: $0.boundingBox, quality: 1, confidence: $0.confidence,
                                    yaw: $0.yaw?.floatValue, roll: $0.roll?.floatValue,
                                    eyesClosed: nil, hasSmile: nil)
                }, error.localizedDescription)
            }
            // フォールバック 2: CIDetector（シミュレータ）。笑顔も同時に取れる。
            return (ciSmileBoxes(in: cg).map {
                FaceObservation(box: $0.box, quality: 1, yaw: nil, roll: nil,
                                eyesClosed: nil, hasSmile: $0.hasSmile)
            }, error.localizedDescription)
        }
    }

    /// IoU 最大（> 0.3）の候補 index。ランドマーク/笑顔観測を品質観測へ対応づける。
    private static func bestMatch(for box: CGRect, in candidates: [CGRect]) -> Int? {
        var best: (index: Int, iou: CGFloat)?
        for (i, c) in candidates.enumerated() {
            let inter = box.intersection(c)
            guard !inter.isNull else { continue }
            let interArea = inter.width * inter.height
            let unionArea = box.width * box.height + c.width * c.height - interArea
            guard unionArea > 0 else { continue }
            let iou = interArea / unionArea
            if iou > 0.3, iou > (best?.iou ?? 0) { best = (i, iou) }
        }
        return best?.index
    }

    /// 顔クロップの画質指標（ぼけ・露出）。64px 正方のグレースケールへ縮小して輝度を取り、
    /// 計算自体は純ロジック（`FaceImageMetrics`）に委譲する（クロップサイズ非依存のスケール）。
    private static func faceMetrics(_ crop: CGImage) -> (blurVariance: Float, meanLuma: Float)? {
        let side = 64
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: side * side)
        var luma = [Float](repeating: 0, count: side * side)
        for i in 0..<(side * side) { luma[i] = Float(buffer[i]) }
        return FaceImageMetrics.compute(luma: luma, width: side, height: side)
    }

    /// ランドマーク領域の中心（ピクセル・原点左下）。
    private static func regionCenter(_ region: VNFaceLandmarkRegion2D?, imageSize: CGSize) -> CGPoint? {
        guard let points = region?.pointsInImage(imageSize: imageSize), !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    /// 口角（外唇の x 最小/最大の点・ピクセル座標）。ArcFace 5 点整列（ADR-70）用。
    private static func lipCorner(_ region: VNFaceLandmarkRegion2D?, imageSize: CGSize,
                                  left: Bool) -> CGPoint? {
        guard let points = region?.pointsInImage(imageSize: imageSize), !points.isEmpty else { return nil }
        return left ? points.min { $0.x < $1.x } : points.max { $0.x < $1.x }
    }

    /// ArcFace 5 点整列の切り抜き（ADR-70）。相似変換（画像ピクセル→112×112 出力・
    /// どちらも原点左下）を CGContext に連結して描くだけ。テンプレート位置に目・鼻・口が揃う。
    private func arcFaceCrop(_ cg: CGImage, transform: CGAffineTransform) -> CGImage? {
        let side = FaceAlignment.arcFaceOutputSide
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.concatenate(transform)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return ctx.makeImage()
    }

    /// アライメント切り抜き（ADR-51）。計画（回転角・出力辺・目標位置）どおりに
    /// CGContext で回転描画する。CGContext は原点左下（y 上向き）＝計画と同じ座標系。
    private func alignedCrop(_ cg: CGImage, plan: FaceAlignmentPlan) -> CGImage? {
        let side = Int(plan.side.rounded())
        guard side >= 16 else { return nil }
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: plan.target.x, y: plan.target.y)
        ctx.rotate(by: -plan.angle)
        ctx.translateBy(x: -plan.eyeMid.x, y: -plan.eyeMid.y)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return ctx.makeImage()
    }

    /// ランドマークから目閉じを近似する（左右とも縦横比 < 0.15 なら閉眼）。
    /// ランドマークが取れない場合は nil（判定しない）。
    private static func eyesClosed(_ landmarks: VNFaceLandmarks2D) -> Bool? {
        func openness(_ region: VNFaceLandmarkRegion2D?) -> CGFloat? {
            guard let points = region?.normalizedPoints, points.count >= 4 else { return nil }
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max(), maxX > minX else { return nil }
            return (maxY - minY) / (maxX - minX)
        }
        guard let left = openness(landmarks.leftEye), let right = openness(landmarks.rightEye) else {
            return nil
        }
        return left < 0.15 && right < 0.15
    }

    /// 笑顔検出用の CIDetector（**使い回す**）。
    /// ⚠️ 以前は写真ごとに `CIDetector(ofType:context: nil, options:)` を生成していた。`context: nil` は
    /// 呼び出しごとに `CIContext` を作るため、顔のある写真すべてでコンテキスト構築コストを払っていた。
    /// CIDetector は生成後 immutable でスレッドセーフ（かつ本経路は ANE ゲートで直列化済み）。
    private static let smileDetector: CIDetector? = CIDetector(
        ofType: CIDetectorTypeFace, context: CIContext(options: nil),
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])

    /// CIDetector（笑顔つき）による顔検出。返り値は Vision と同じ正規化・原点左下の矩形。
    /// `CIFaceFeature.bounds` は画像座標・原点左下なので W/H で割る。
    /// 笑顔は `FaceStore` の代表顔スコア（`quality + hasSmile*0.3 + …`）に効くので、Vision で顔が
    /// 取れている写真に対してのみ、この 2 本目のパスを走らせる（呼び出し側で顔ゼロは弾いている）。
    private func ciSmileBoxes(in cg: CGImage) -> [(box: CGRect, hasSmile: Bool)] {
        let ci = CIImage(cgImage: cg)
        let features = Self.smileDetector?.features(in: ci, options: [CIDetectorSmile: true]) ?? []
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        guard width > 0, height > 0 else { return [] }
        return features.compactMap { $0 as? CIFaceFeature }.map {
            (CGRect(x: $0.bounds.origin.x / width, y: $0.bounds.origin.y / height,
                    width: $0.bounds.width / width, height: $0.bounds.height / height),
             $0.hasSmile)
        }
    }

    /// Vision の正規化 bbox（原点左下・y 上向き）→ CGImage のピクセル矩形（原点左上）へ変換し、
    /// 顔の周囲にマージンを付けて切り抜く（顔モデルは輪郭周辺も使うため）。
    private func cropFace(_ cg: CGImage, normalizedBox: CGRect, width: CGFloat, height: CGFloat) -> CGImage? {
        let margin: CGFloat = 0.3
        var box = normalizedBox.insetBy(dx: -normalizedBox.width * margin, dy: -normalizedBox.height * margin)
        box = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isNull else { return nil }
        let pixel = CGRect(
            x: box.origin.x * width,
            y: (1 - box.origin.y - box.height) * height,   // y 反転
            width: box.width * width,
            height: box.height * height).integral
        guard pixel.width >= 1, pixel.height >= 1 else { return nil }
        return cg.cropping(to: pixel)
    }
}
