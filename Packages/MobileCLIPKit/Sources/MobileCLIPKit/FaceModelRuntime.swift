import AutoAlbumCore   // MLInferenceGate（PerceptionCore を再エクスポート）
import CoreML
import MosaicSupport
import UIKit

/// 顔認識モデル（FaceEmbedder.mlmodelc）が同梱されているか、ロードを発生させずに判定する。
public enum FaceModel {
    public static var modelBundled: Bool {
        Bundle.main.url(forResource: "FaceEmbedder", withExtension: "mlmodelc") != nil
    }
}

/// 同梱した顔認識モデル（Core ML・facenet InceptionResnetV1）を読み込み、顔切り抜き画像を
/// 512 次元 L2 正規化埋め込みへ変換する。未同梱なら `isAvailable == false` でピープルは無効。
/// 入力リサイズ（160x160）と正規化はモデル側に内包（`MLFeatureValue(cgImage:constraint:)` が自動）。
final class FaceModelRuntime: @unchecked Sendable {
    static let shared = FaceModelRuntime()
    private static let log = LogChannel(subsystem: "com.mosaicphotos.MobileCLIPKit", label: "Faces")

    /// 同梱判定（**ロードを起こさない**）。以前は `.shared` に触れた瞬間に init が同期ロードしていた
    /// ため、`isFaceModelAvailable` を評価するホーム描画（メインスレッド）で facenet が読まれていた
    /// （People を開かなくても起動時にロード＝1-a）。CLIP/VLM と同じく同梱判定は URL チェックのみに。
    var isAvailable: Bool { FaceModel.modelBundled }

    private let box = LoadOnce<CoreMLModelHandle>()
    private let config = CoreMLModelLoader.makeConfiguration()

    private init() {
        // 1-d: critical 圧迫でのみ解放する（facenet は CLIP 画像塔より軽いが、常駐させる理由もない）。
        // warning で手放すと夜間の顔スキャン中に再ロードを繰り返すため、critical 限定にする。
        _ = MemoryPressureMonitor.shared.register { [weak self] level in
            guard level == .critical else { return }
            self?.release()
        }
    }

    /// ロード済み顔モデルを解放する（critical 圧迫時）。次回の embed で再ロードされる。
    /// **同期**で完了させる（圧迫ハンドラから呼ばれるため）。
    private func release() {
        guard box.isLoaded else { return }
        box.reset()
        Self.log.info("face model released (memory pressure)")
    }

    /// 初回利用まで遅延ロードする（`LoadOnce`・二重ロード防止＋失敗は再試行しない）。
    private func handle() async -> CoreMLModelHandle? {
        // 止めた直後に 10 秒級のロードを始めない（ADR-95 追記）。
        if CoreMLModelLoader.skipLoadWhenCancelled(isLoaded: box.isLoaded, subject: "face model") {
            return nil
        }
        return await box.get { [config] in
            await CoreMLModelLoader.loadBundledModel(named: "FaceEmbedder", configuration: config,
                                                     log: Self.log, subject: "face model")
                .map(CoreMLModelHandle.init)
        }
    }

    // MARK: - 推論（ANE 直列化ゲートの内側で実行・`unsafe*` は保持済み前提）

    /// 顔切り抜き画像 → 512 次元 L2 正規化埋め込み。NaN/Inf は壊れとみなし nil
    /// （有限性ガードは CoreMLModelHandle 側で共通に行う）。
    func embed(_ cgImage: CGImage) async -> [Float]? {
        await MLInferenceGate.shared.run { await self.unsafeEmbed(cgImage) }
    }

    private func unsafeEmbed(_ cgImage: CGImage) async -> [Float]? {
        await handle()?.predictVector(from: cgImage)
    }

    /// 候補B: 複数の顔クロップを**バッチ推論**する（CLIP の `encodeImages` と同型）。
    /// 1 枚の写真の複数顔×マルチクロップ（アライメント/反転/bbox）をまとめて 1 回の ANE 呼び出しに
    /// でき、顔ごと・クロップごとの単発推論の呼び出しオーバーヘッドを償却する（精度は不変）。
    /// 返り値は入力と同じ並び（変換失敗・非有限は nil）。バッチ失敗時は 1 枚ずつへフォールバック。
    func embed(_ images: [CGImage]) async -> [[Float]?] {
        guard !images.isEmpty else { return [] }
        return await MLInferenceGate.shared.run { await self.unsafeEmbed(images) }
    }

    private func unsafeEmbed(_ images: [CGImage]) async -> [[Float]?] {
        guard images.count > 1, let handle = await handle() else {
            var out: [[Float]?] = []
            for cg in images { out.append(await unsafeEmbed(cg)) }
            return out
        }
        var providers: [MLFeatureProvider] = []
        var indexMap: [Int] = []
        for (index, cg) in images.enumerated() {
            guard let provider = handle.imageProvider(for: cg) else { continue }
            providers.append(provider)
            indexMap.append(index)
        }
        var results: [[Float]?] = Array(repeating: nil, count: images.count)
        guard !providers.isEmpty else { return results }
        if let out = try? handle.model.predictions(fromBatch: MLArrayBatchProvider(array: providers)) {
            // 範囲外アクセス回避（CLIP 側と同じ理由）。
            for i in 0..<min(out.count, indexMap.count) {
                results[indexMap[i]] = handle.vector(from: out.features(at: i))
            }
            return results
        }
        for (i, cg) in images.enumerated() { results[i] = await unsafeEmbed(cg) }
        return results
    }
}
