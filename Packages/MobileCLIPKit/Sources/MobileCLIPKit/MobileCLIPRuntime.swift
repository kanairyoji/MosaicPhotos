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
    private let imageBox = LoadOnce<CoreMLModelHandle>()
    private let textBox = LoadOnce<CoreMLModelHandle>()

    private init() {
        config = CoreMLModelLoader.makeConfiguration()
        isAvailable = MobileCLIP.modelsBundled
        if !isAvailable {
            Self.log.info("CLIP models not bundled — AI search disabled")
        }
    }

    // MARK: - タワー別の遅延ロード（スレッドセーフ・失敗は一度だけ記録）

    private func loadTower(_ name: String, label: String) -> CoreMLModelHandle? {
        CoreMLModelLoader.loadBundledModel(named: name, configuration: config,
                                           log: Self.log, subject: "CLIP \(label) tower")
            .map(CoreMLModelHandle.init)
    }

    /// テキスト塔（軽い方）。検索・AI アルバム再評価・表示タグの概念埋め込みが使う。
    private func textModel() -> CoreMLModelHandle? {
        textBox.get { loadTower("MobileCLIPTextS2", label: "text") }
    }

    /// 画像塔（重い方）。背景の CLIP 埋め込み（heavy ゲート内）だけが使う。
    private func imageModel() -> CoreMLModelHandle? {
        imageBox.get { loadTower("MobileCLIPImageS2", label: "image") }
    }

    // MARK: - 推論（MLModel はスレッドセーフ・ロック外で実行）

    /// トークン ID 列（長さ 77）→ 正規化済み 512 次元埋め込み。
    func encodeText(_ tokens: [Int32]) -> [Float]? {
        guard let text = textModel(),
              let arr = try? MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32)
        else { return nil }
        let ptr = arr.dataPointer.bindMemory(to: Int32.self, capacity: tokens.count)
        for i in tokens.indices { ptr[i] = tokens[i] }
        guard let provider = try? MLDictionaryFeatureProvider(
                dictionary: [text.inputName: MLFeatureValue(multiArray: arr)]),
              let out = try? text.model.prediction(from: provider)
        else { return nil }
        return text.vector(from: out)
    }

    /// P1: 複数画像の**バッチ推論**。1 枚ずつ prediction するより呼び出しオーバーヘッドが
    /// 償却され、backlog 消化のスループットが 2〜4 倍になる（ANE はバッチに強い）。
    /// 返り値は入力と同じ並び（変換失敗・非有限は nil）。バッチ予測が失敗したら 1 枚ずつに
    /// フォールバックする（安全側）。
    func encodeImages(_ images: [CGImage]) -> [[Float]?] {
        guard !images.isEmpty else { return [] }
        guard images.count > 1 else { return [encodeImage(images[0])] }
        guard let image = imageModel() else {
            return images.map { _ in nil }
        }
        // 変換に成功した画像だけでバッチを組み、元の並びへ書き戻す。
        var providers: [MLFeatureProvider] = []
        var indexMap: [Int] = []   // providers[i] → images のインデックス
        for (index, cg) in images.enumerated() {
            guard let provider = image.imageProvider(for: cg) else { continue }
            providers.append(provider)
            indexMap.append(index)
        }
        var results: [[Float]?] = Array(repeating: nil, count: images.count)
        guard !providers.isEmpty else { return results }

        if let out = try? image.model.predictions(fromBatch: MLArrayBatchProvider(array: providers)) {
            for i in 0..<out.count {
                results[indexMap[i]] = image.vector(from: out.features(at: i))
            }
            return results
        }
        // バッチ失敗 → 1 枚ずつ（従来経路）で救済。
        for (i, cg) in images.enumerated() { results[i] = encodeImage(cg) }
        return results
    }

    /// 画像 → 正規化済み 512 次元埋め込み。リサイズ/画素変換はモデルの画像制約に従い自動。
    /// NaN/Inf 破棄（有限性ガード）は CoreMLModelHandle 側で共通に行う。
    func encodeImage(_ cgImage: CGImage) -> [Float]? {
        imageModel()?.predictVector(from: cgImage)
    }
}
