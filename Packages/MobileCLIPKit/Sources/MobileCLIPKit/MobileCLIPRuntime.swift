import AutoAlbumCore   // MLInferenceGate（PerceptionCore を再エクスポート）
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
        // 1-d: critical 圧迫では両タワーを解放する（画像塔が重い）。warning では解放しない
        // ——再ロードが 16〜35 秒と高価で、軽い圧迫のたびに手放すと復帰コストの方が大きいため。
        _ = MemoryPressureMonitor.shared.register { [weak self] level in
            guard level == .critical else { return }
            self?.releaseAll()
        }
    }

    /// ロード済みタワーを解放する（critical 圧迫時）。次回の encode で再ロードされる。
    /// 実行中の推論は自分のハンドルを強参照しているので、途中で消えることはない。
    /// **同期**で完了させる——圧迫ハンドラから呼ばれるので、`Task` に逃がすと解放が後回しになる。
    private func releaseAll() {
        let wasLoaded = imageBox.isLoaded || textBox.isLoaded
        imageBox.reset()
        textBox.reset()
        if wasLoaded { Self.log.info("CLIP towers released (memory pressure)") }
    }

    // MARK: - タワー別の遅延ロード（二重ロード防止・失敗は一度だけ記録）

    /// テキスト塔（軽い方）。検索・AI アルバム再評価・表示タグの概念埋め込みが使う。
    private func textModel() async -> CoreMLModelHandle? {
        await textBox.get { [config] in
            await CoreMLModelLoader.loadBundledModel(named: "MobileCLIPTextS2", configuration: config,
                                                     log: Self.log, subject: "CLIP text tower")
                .map(CoreMLModelHandle.init)
        }
    }

    /// 画像塔（重い方）。背景の CLIP 埋め込み（heavy ゲート内）だけが使う。
    private func imageModel() async -> CoreMLModelHandle? {
        await imageBox.get { [config] in
            await CoreMLModelLoader.loadBundledModel(named: "MobileCLIPImageS2", configuration: config,
                                                     log: Self.log, subject: "CLIP image tower")
                .map(CoreMLModelHandle.init)
        }
    }

    // MARK: - 推論（ANE 直列化ゲートの内側で実行）
    //
    // ⚠️ ゲートは**ここ**で掛ける。呼び出し側（PhotoTagger・検索の QueryEmbedder 等）に任せると
    // 前景の検索経路のように素通りするものが出る（実際に出ていた＝diagnostics-19 の再発条件）。
    // ロード（数十秒）もゲート内に含める＝ロード中に他の ANE 処理を走らせない。
    // `unsafe*` は既にゲートを保持している前提の内部実装。入れ子で `run` を呼ばないこと。

    /// トークン ID 列（長さ 77）→ 正規化済み 512 次元埋め込み。
    /// `priority` は ANE ゲートの待機列の選択（ADR-75）。検索・AI アルバム作成のように**ユーザーが
    /// 結果を待っている**呼び出しは `.interactive` を渡し、夜間のウォームアップや約300語の概念埋め込み
    /// 構築は既定の `.background` のままにする。
    func encodeText(_ tokens: [Int32],
                    priority: MLInferencePriority = .background) async -> [Float]? {
        await MLInferenceGate.shared.run(priority: priority) { await self.unsafeEncodeText(tokens) }
    }

    private func unsafeEncodeText(_ tokens: [Int32]) async -> [Float]? {
        guard let text = await textModel(),
              let arr = try? MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32)
        else { return nil }
        let ptr = arr.dataPointer.bindMemory(to: Int32.self, capacity: tokens.count)
        for i in tokens.indices { ptr[i] = tokens[i] }
        guard let provider = try? MLDictionaryFeatureProvider(
                dictionary: [text.inputName: MLFeatureValue(multiArray: arr)]),
              // async オーバーロード（Core ML 側でオフロード）。前景の検索から呼ばれる経路なので
              // 協調スレッドを推論の間ブロックしない。VLMRuntime も同じ形。
              let out = try? await text.model.prediction(from: provider)
        else { return nil }
        return text.vector(from: out)
    }

    /// P1: 複数画像の**バッチ推論**。1 枚ずつ prediction するより呼び出しオーバーヘッドが
    /// 償却され、backlog 消化のスループットが 2〜4 倍になる（ANE はバッチに強い）。
    /// 返り値は入力と同じ並び（変換失敗・非有限は nil）。バッチ予測が失敗したら 1 枚ずつに
    /// フォールバックする（安全側）。
    func encodeImages(_ images: [CGImage]) async -> [[Float]?] {
        guard !images.isEmpty else { return [] }
        return await MLInferenceGate.shared.run { await self.unsafeEncodeImages(images) }
    }

    private func unsafeEncodeImages(_ images: [CGImage]) async -> [[Float]?] {
        guard images.count > 1 else { return [await unsafeEncodeImage(images[0])] }
        guard let image = await imageModel() else {
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
            // out.count は providers.count と一致するはずだが、信じて indexMap を引くと
            // 食い違ったときに範囲外アクセスで落ちる。少ない方に合わせる（安全側）。
            for i in 0..<min(out.count, indexMap.count) {
                results[indexMap[i]] = image.vector(from: out.features(at: i))
            }
            return results
        }
        // バッチ失敗 → 1 枚ずつ（従来経路）で救済。
        for (i, cg) in images.enumerated() { results[i] = await unsafeEncodeImage(cg) }
        return results
    }

    /// 画像 → 正規化済み 512 次元埋め込み。リサイズ/画素変換はモデルの画像制約に従い自動。
    /// NaN/Inf 破棄（有限性ガード）は CoreMLModelHandle 側で共通に行う。
    func encodeImage(_ cgImage: CGImage) async -> [Float]? {
        await MLInferenceGate.shared.run { await self.unsafeEncodeImage(cgImage) }
    }

    private func unsafeEncodeImage(_ cgImage: CGImage) async -> [Float]? {
        await imageModel()?.predictVector(from: cgImage)
    }
}
