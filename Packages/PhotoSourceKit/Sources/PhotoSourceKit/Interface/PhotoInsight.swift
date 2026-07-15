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

    /// 表示タグ（Vision シーンタグ＋CLIP ゼロショットの補完）。検索のタグ台帳と同一ソース。
    public var tags: [String]
    public var people: [String]
    /// VLM キャプション（英語・夜間バッチで後から埋まる）。未生成は nil。
    public var caption: String?
    /// キャプションがこれから生成される見込みか（VLM 同梱かつ未生成）。true のとき「生成中」を出す。
    public var captionPending: Bool
    /// この写真で検出した顔の数（顔スキャン済みのみ・実測）。未スキャン（クラウド含む）は nil。
    public var faceCount: Int?
    /// スクリーンショット判定（撮影ではなく画面キャプチャか）。
    public var isScreenshot: Bool
    /// Dropbox へバックアップ済みか。nil = 対象外（クラウド写真）または判定不能。
    public var isBackedUp: Bool?
    public var status: Status

    public init(tags: [String] = [], people: [String] = [], caption: String? = nil,
                captionPending: Bool = false,
                faceCount: Int? = nil, isScreenshot: Bool = false,
                isBackedUp: Bool? = nil,
                status: Status = .ready) {
        self.tags = tags
        self.people = people
        self.caption = caption
        self.captionPending = captionPending
        self.faceCount = faceCount
        self.isScreenshot = isScreenshot
        self.isBackedUp = isBackedUp
        self.status = status
    }

    public var hasSignals: Bool {
        !tags.isEmpty || !people.isEmpty || (faceCount ?? 0) > 0 || caption != nil
    }
}
