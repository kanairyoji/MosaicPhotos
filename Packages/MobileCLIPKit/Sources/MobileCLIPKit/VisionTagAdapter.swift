import AutoAlbumCore
import CoreGraphics
import Foundation
import MosaicSupport
import Photos
import Vision

/// `TagPerceptionProvider` の実体。
/// - 付帯情報（photo-info-expansion）: **1 回の `VNImageRequestHandler.perform([...])`** で
///   シーン分類・OCR・動物種別・人物矩形・美的スコアを一括取得する（前処理・ロードを共有）。
///   - シーンタグ: `VNClassifyImageRequest`（約1,300クラス）。信頼度は Apple が校正済みで、
///     `hasMinimumRecall(_:forPrecision:)` により「精度 0.9 を満たすタグだけ採る」原理的な足切り。
///   - OCR: `VNRecognizeTextRequest`（accurate・言語自動判定）。看板・書類・スクショの文字。
///   - 動物: `VNRecognizeAnimalsRequest`（cat/dog）。分類より確実なのでタグへ合流。
///   - 人物数: `VNDetectHumanRectanglesRequest`（上半身）。
///   - 美的スコア: `VNCalculateImageAestheticsScoresRequest`（iOS 18+・-1〜1）。
///   さらにローカル写真は PHAsset の種別（スクショ/パノラマ/Live Photo 等）をタグに合流する。
/// - キャプション: SmolVLM（同梱時のみ・`VLMRuntime`）。
public struct VisionTagAdapter: TagPerceptionProvider {
    /// クラウド path → CGImage（Dropbox サムネイル）。CLIPEmbeddingProvider と同じ seam。
    let cloudImage: @Sendable (String) async -> CGImage?
    /// クラウド path 群のサムネを**一括で先行取得**するヒント（ADR-83・即座に返る）。
    let warmCloud: (@Sendable ([String]) -> Void)?

    public init(cloudImage: @escaping @Sendable (String) async -> CGImage?,
                warmCloud: (@Sendable ([String]) -> Void)? = nil) {
        self.cloudImage = cloudImage
        self.warmCloud = warmCloud
    }

    public func warmUp(refKeys: [String]) {
        warmCloudPaths(refKeys, using: warmCloud)
    }

    public var isTaggingAvailable: Bool { true }   // Vision は OS 内蔵

    public func senseInfo(refKeys: [String]) async -> [String: PhotoSenseInfo] {
        guard !refKeys.isEmpty else { return [:] }
        let cloud = cloudImage
        // 候補C: **画像ロードだけ**を同時数枚まで並列化する（PHImageManager のデコード／Dropbox サムネ
        // 取得＝ANE を使わない I/O なので並列で得をする）。Vision 一括パス（`sense`）は内部で ANE 直列化
        // ゲートを取るため、ここで 3 並列にしても推論は 1 つずつ実行される。
        // ⚠️ 以前は呼び出し側（TagTagger）がゲートを取った**内側**でこの 3 並列が回っており、
        //    「ANE は同時に 1 つ」という不変条件をゲートの内側で破っていた（diagnostics-19 の再発条件）。
        // 取得不可の写真も空 info を返して「処理済み」にし無限ループを防ぐ。
        return await boundedConcurrentResults(refKeys, maxConcurrent: 3) { refKey in
            guard let ref = PhotoRef.decode(refKey) else { return PhotoSenseInfo() }
            if let localId = ref.localIdentifier {
                // 候補C: PHAsset は **1 回だけ**フェッチして画像取得と種別タグで共用（再フェッチ削減）。
                // OCR は解像度が要る（384px では小文字が潰れる）ため 1024px（分類は内部で縮小）。
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localId],
                                                      options: nil).firstObject,
                      let cg = await PHAssetImageLoader.image(
                          for: asset, targetSize: CGSize(width: 1024, height: 1024),
                          quality: .full, allowsNetwork: false)?.cgImage
                else { return PhotoSenseInfo() }
                var info = await Self.sense(cg)
                info.tags = Self.mergeTags(info.tags, adding: Self.assetKindTags(from: asset))
                return info
            } else if let path = ref.cloudPath {
                guard let cg = await cloud(path) else { return PhotoSenseInfo() }
                return await Self.sense(cg)
            }
            return PhotoSenseInfo()
        }
    }

    /// Vision 一括パス（1 回の perform で全リクエストを実行）。
    /// ANE 直列化ゲートは**ここ**で掛ける（呼び出し側の TagTagger では包まない）。
    static func sense(_ cg: CGImage) async -> PhotoSenseInfo {
        await MLInferenceGate.shared.run { unsafeSense(cg) }
    }

    /// ゲート保持済み前提の本体（入れ子で `run` を呼ばないこと）。
    private static func unsafeSense(_ cg: CGImage) -> PhotoSenseInfo {
        let classify = VNClassifyImageRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.automaticallyDetectsLanguage = true
        let animals = VNRecognizeAnimalsRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = true   // 顔が写らない後ろ姿・上半身も人数に含める

        var requests: [VNRequest] = [classify, text, animals, humans]
        var aestheticsRequest: VNRequest?
        if #available(iOS 18.0, macOS 15.0, *) {
            let r = VNCalculateImageAestheticsScoresRequest()
            aestheticsRequest = r
            requests.append(r)
        }

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform(requests)) != nil else { return PhotoSenseInfo() }

        // シーンタグ（精度 0.75・最大 25 個・信頼度順）。検索インデックスは広めに取る
        // （表示は insight 側で上位 10 に絞る＝役割別の 2 段構成）。
        var tags = (classify.results ?? [])
            .filter { $0.hasMinimumRecall(0.01, forPrecision: 0.75) }
            .sorted { $0.confidence > $1.confidence }
            .prefix(25)
            .map(\.identifier)

        // 動物種別（cat/dog）。専用検出器の方が分類より確実なのでタグへ合流する。
        let animalTags = (animals.results ?? []).flatMap { observation in
            observation.labels.filter { $0.confidence >= 0.7 }.map { $0.identifier.lowercased() }
        }
        tags = mergeTags(tags, adding: animalTags)

        // OCR（低信頼の誤読を足切りし、信頼度順に連結・最大 300 文字＝台帳を太らせない）。
        let lines = (text.results ?? []).compactMap { obs -> String? in
            guard let candidate = obs.topCandidates(1).first,
                  candidate.confidence >= 0.3 else { return nil }
            return candidate.string
        }
        let joined = lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let ocr = joined.isEmpty ? nil : String(joined.prefix(300))

        let humanCount = humans.results?.count ?? 0

        var aesthetic: Double?
        if #available(iOS 18.0, macOS 15.0, *),
           let r = aestheticsRequest as? VNCalculateImageAestheticsScoresRequest,
           let score = r.results?.first?.overallScore {
            aesthetic = Double(score)
        }

        return PhotoSenseInfo(tags: tags, ocrText: ocr, humanCount: humanCount, aesthetic: aesthetic)
    }

    /// PHAsset の種別タグ（スクショ/パノラマ/Live Photo/HDR/ポートレート/バースト）。
    /// 1 行で取れる高信頼シグナル（photo-info-expansion 項目 3）。検索タグ・表示タグ共用。
    static func assetKindTags(localIdentifier: String) -> [String] {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier],
                                              options: nil).firstObject else { return [] }
        return assetKindTags(from: asset)
    }

    /// フェッチ済み PHAsset から種別タグ（senseInfo が画像取得で使った asset を再利用＝再フェッチ削減）。
    static func assetKindTags(from asset: PHAsset) -> [String] {
        var tags: [String] = []
        let sub = asset.mediaSubtypes
        if sub.contains(.photoScreenshot) { tags.append("screenshot") }
        if sub.contains(.photoPanorama) { tags.append("panorama") }
        if sub.contains(.photoLive) { tags.append("live photo") }
        if sub.contains(.photoHDR) { tags.append("hdr") }
        if sub.contains(.photoDepthEffect) { tags.append("portrait") }
        if asset.representsBurst { tags.append("burst") }
        return tags
    }

    /// タグ集合の合流（小文字比較で重複除去・元の順序維持）。
    static func mergeTags(_ base: [String], adding extra: [String]) -> [String] {
        var seen = Set(base.map { $0.lowercased() })
        var out = base
        for tag in extra where !seen.contains(tag.lowercased()) {
            seen.insert(tag.lowercased())
            out.append(tag)
        }
        return out
    }

    // MARK: - キャプション（SmolVLM・P3）

    public var isCaptioningAvailable: Bool { VLMRuntime.shared.isAvailable }

    /// キャプション後に VLM(≈877MB) を解放し、CLIP 画像塔・facenet と同時常駐させない（1-d）。
    public func releaseCaptionModelIfLoaded() { VLMRuntime.shared.release() }

    public func captions(refKeys: [String]) async -> [String: String] {
        guard VLMRuntime.shared.isAvailable else { return [:] }
        var out: [String: String] = [:]
        for refKey in refKeys {
            await Task.yield()
            guard let ref = PhotoRef.decode(refKey) else { continue }
            let cg: CGImage?
            if let localId = ref.localIdentifier {
                cg = await loadLocalCGImage(localId, maxPixel: 512)
            } else if let path = ref.cloudPath {
                cg = await cloudImage(path)
            } else {
                cg = nil
            }
            guard let cg else { continue }
            if let caption = await VLMRuntime.shared.caption(for: cg) {
                out[refKey] = caption
            }
        }
        return out
    }
}
