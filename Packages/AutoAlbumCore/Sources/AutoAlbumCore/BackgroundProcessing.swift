import Foundation

/// バックグラウンド埋め込み（CLIP 付与）の「重さ」プリセット。複数パラメータ（1バッチの件数・
/// バッチ間の休止秒）を1つの段階にまとめ、設定画面で段階選択できるようにする。
/// 段ごとに何がどう変わるか（batchSize / pauseSeconds）を UI でそのまま提示する。
public struct BackgroundProcessingPreset: Sendable, Identifiable, Equatable {
    public let id: Int               // 0 始まりの段階インデックス
    public let name: String          // 表示名
    public let batchSize: Int        // 1バッチで処理する写真数
    public let pauseSeconds: Double  // バッチ間の休止（秒）

    public var betweenBatchNs: UInt64 { UInt64(pauseSeconds * 1_000_000_000) }
}

public enum BackgroundProcessing {
    /// 軽い（端末・通信・UI に優しい）→ 速い（重い）順。
    public static let presets: [BackgroundProcessingPreset] = [
        .init(id: 0, name: "Very Gentle", batchSize: 4,  pauseSeconds: 6.0),
        .init(id: 1, name: "Gentle",      batchSize: 8,  pauseSeconds: 2.5),
        .init(id: 2, name: "Balanced",    batchSize: 16, pauseSeconds: 1.0),
        .init(id: 3, name: "Fast",        batchSize: 32, pauseSeconds: 0.2),
    ]

    /// 既定は "Gentle"（現行のスロットル相当）。
    public static let defaultIndex = 1

    public static func preset(at index: Int) -> BackgroundProcessingPreset {
        presets[min(max(0, index), presets.count - 1)]
    }
}
