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
            // ⚠️ **画像を取りに行く前に**降りる（実機 diagnostics-56）。以前はキャンセル判定が
            // ループの末尾（ロード＋推論の後）にしか無く、1 キー呼び出しでは事実上機能しなかった。
            // 前面復帰で `stopScan` した 22:06:01 のスキャンが実際に終わったのは 22:06:14＝**13 秒後**で、
            // その間ずっとクラウド 1024px のダウンロード（実測 7.5 秒）と ANE 推論を握り続けていた。
            // 「操作が来たら即譲る」（CLAUDE.md 背景処理の不変条件）を満たすには、重い段の**前**で見る。
            if Task.isCancelled { break }
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
            // ロードは待たされ得る（クラウドは往復・実測 7.5 秒）。取れた直後にもう一度見て、
            // **推論へ入らない**（ANE ゲートを掴むと他の解析も道連れになる）。
            // ここで抜けた写真は結果に載らない＝下流は「未解析」として次の窓に回す（ADR-92）。
            if Task.isCancelled { break }
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
    /// ⚠️ internal: Vision の観測部分を `+Vision` へ分けたので、同じ型の別ファイルから見える必要がある
    /// （`private` だと Vision の同名 API＝iOS 18 に解決されてしまう）。
    struct FaceObservation {
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
}
