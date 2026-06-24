import Foundation

/// フル画像ビューで表示する、AI/Vision 等で抽出した付帯情報（タグ・画像内文字・人物）。
/// SwiftUI 非依存の値型なので、ロジック層（AutoAlbumCore など）からも生成できる。
public struct PhotoInsight: Sendable, Equatable {
    /// 解析の進行状態（UI で「未処理／解析中／完了」を区別表示するため）。
    public enum Status: Sendable {
        case notIndexed   // まだ取り込み（付加情報生成）されていない
        case analyzing    // 取り込み済みだがタグ/OCR は背景処理待ち
        case ready        // 解析完了（タグ 0 件でも完了）
    }

    /// 表示専用の CLIP ゼロショットタグ（dog/beach/sunset 等）。検索は語彙ゼロのまま、これは表示専用。
    public var tags: [String]
    public var people: [String]
    public var status: Status

    public init(tags: [String] = [], people: [String] = [], status: Status = .ready) {
        self.tags = tags
        self.people = people
        self.status = status
    }

    public var hasSignals: Bool {
        !tags.isEmpty || !people.isEmpty
    }
}
