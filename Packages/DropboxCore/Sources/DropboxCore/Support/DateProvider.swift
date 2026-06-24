import Foundation

/// 現在時刻の抽象。本番は `SystemDateProvider`、テストは固定時刻を注入することで、
/// トークン期限判定などの時刻依存ロジックを決定的に検証できる。
///
/// 名称は Swift 標準ライブラリの `Clock` と衝突させないため `DateProvider` とする。
public protocol DateProvider: Sendable {
    var now: Date { get }
}

/// 本番用の実時計実装。
public struct SystemDateProvider: DateProvider {
    public init() {}
    public var now: Date { Date() }
}
