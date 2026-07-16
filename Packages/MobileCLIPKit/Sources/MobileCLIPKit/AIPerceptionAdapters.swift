import AutoAlbumCore
import os
import Photos
import UIKit

/// 写真1枚の **CLIP 画像埋め込み**だけを計算する知覚プロバイダ（オンデバイス・MobileCLIP）。
/// 検索は語彙ゼロのオープン語彙 CLIP に一本化したため、OCR・固定語彙タグは持たない。
/// ローカル（PHAsset）とクラウド（Dropbox サムネイル）の双方を refKey から解決して埋め込む。
public struct CLIPEmbeddingProvider: PhotoPerceptionProvider {

    /// クラウド path → CGImage（Dropbox サムネイル）を返すローダ。アプリが DropboxPhotoStore を背後に注入。
    let cloudImage: @Sendable (String) async -> CGImage?

    public init(cloudImage: @escaping @Sendable (String) async -> CGImage?) {
        self.cloudImage = cloudImage
    }

    nonisolated static let log = Logger(subsystem: "com.mosaicphotos.AutoAlbum", category: "embed")

    // ⚠️ アプリターゲットは SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor。明示的に nonisolated に
    // しないと画像取得と CLIP がメインスレッドで走り、ハング/UI 凍結する。
    public nonisolated func perceive(refKeys: [String]) async -> [String: PhotoPerception] {
        guard !refKeys.isEmpty else { return [:] }
        let clip = MobileCLIPRuntime.shared
        guard clip.isAvailable else {
            Self.log.notice("embed: skipped — MobileCLIP unavailable")
            return [:]   // タガーが空＝処理済みとして扱う
        }
        Self.log.notice("embed: begin \(refKeys.count, privacy: .public) photos")

        var byKey: [String: PhotoPerception] = [:]
        var noImage = 0, embedded = 0

        // 1) 画像ロード（P2: CLIP 入力は 224px なので 256px で十分＝取得/変換/メモリが約 1/4）。
        var images: [CGImage] = []
        var imageKeys: [String] = []
        for refKey in refKeys {
            await Task.yield()   // UI 操作中は協調的に後回し
            guard let ref = PhotoRef.decode(refKey) else { continue }
            let cg: CGImage?
            if let localId = ref.localIdentifier {
                cg = await loadLocalCGImage(localId, maxPixel: 256)
            } else if let path = ref.cloudPath {
                cg = await cloudImage(path)
            } else {
                cg = nil
            }
            guard let cg else {
                noImage += 1
                byKey[refKey] = PhotoPerception()   // 取得不可でも「処理済み」にする
                continue
            }
            images.append(cg)
            imageKeys.append(refKey)
        }

        // 2) バッチ推論（P1: 1 枚ずつより 2〜4 倍のスループット。失敗時は runtime 内で単発へ救済）。
        let vectors = clip.encodeImages(images)
        for (i, refKey) in imageKeys.enumerated() {
            let vector = vectors[i].map { ClipMath.encode($0) }
            if vector != nil { embedded += 1 }
            byKey[refKey] = PhotoPerception(clipVector: vector)
        }
        Self.log.notice("embed: \(byKey.count, privacy: .public) results — \(embedded, privacy: .public) embedded, \(noImage, privacy: .public) no-image")
        return byKey
    }
}

/// 検索文 → CLIP テキスト埋め込み（MobileCLIP-S2・Core ML）。
/// 入力は上流（QueryTranslator）で英語に正規化済みのため、ここではトークナイズ→
/// テキストエンコーダで 512 次元を返すだけ。モデル未同梱時は無効。
public struct MobileCLIPTextEmbedder: TextEmbedder {
    public init() {}

    public var isAvailable: Bool { MobileCLIPRuntime.shared.isAvailable && CLIPTokenizer.shared != nil }

    public func embed(_ text: String) async -> [Float]? {
        guard MobileCLIPRuntime.shared.isAvailable, let tokenizer = CLIPTokenizer.shared else { return nil }
        let tokens = tokenizer.encode(text)
        return await Task.detached(priority: .userInitiated) {
            MobileCLIPRuntime.shared.encodeText(tokens)
        }.value
    }

    /// テキストタワーの遅延ロード（Core ML コンパイル・初回数秒）を **utility 優先度**で前倒しする。
    /// userInitiated だと画面遷移アニメーションと性能コアを奪い合い、コンポーザーの開閉が
    /// もたつく（実障害）。ウォームアップは急がない＝低優先度で十分。
    public func prewarm() async {
        await Task.detached(priority: .utility) {
            guard MobileCLIPRuntime.shared.isAvailable, let tokenizer = CLIPTokenizer.shared else { return }
            _ = MobileCLIPRuntime.shared.encodeText(tokenizer.encode("a photo"))
        }.value
    }
}
