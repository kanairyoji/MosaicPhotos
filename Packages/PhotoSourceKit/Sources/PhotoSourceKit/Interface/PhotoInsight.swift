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
    /// 写真内テキスト（OCR・photo-info-expansion）。未検出は nil。
    public var ocrText: String?
    /// 利用カウンタ（フル画面の閲覧/再生/共有・記録なしは nil＝0 扱いで表示）。
    public var viewCount: Int?
    public var playCount: Int?
    public var shareCount: Int?
    /// この写真で検出した顔の数（顔スキャン済みのみ・実測）。未スキャン（クラウド含む）は nil。
    public var faceCount: Int?
    /// スクリーンショット判定（撮影ではなく画面キャプチャか）。
    public var isScreenshot: Bool
    /// Dropbox へバックアップ済みか。nil = 対象外（クラウド写真）または判定不能。
    public var isBackedUp: Bool?
    /// この写真の保存場所（端末 / Dropbox）。同じ写真でも入手経路が違うと挙動（解析解像度・
    /// バックアップ対象か）が変わるため、ユーザーが区別できるように出す。
    public enum Source: Sendable { case local, cloud }
    public var source: Source?
    public var status: Status

    public init(tags: [String] = [], people: [String] = [], caption: String? = nil,
                captionPending: Bool = false, ocrText: String? = nil,
                viewCount: Int? = nil, playCount: Int? = nil, shareCount: Int? = nil,
                faceCount: Int? = nil, isScreenshot: Bool = false,
                isBackedUp: Bool? = nil, source: Source? = nil,
                status: Status = .ready) {
        self.tags = tags
        self.people = people
        self.caption = caption
        self.captionPending = captionPending
        self.ocrText = ocrText
        self.viewCount = viewCount
        self.playCount = playCount
        self.shareCount = shareCount
        self.faceCount = faceCount
        self.isScreenshot = isScreenshot
        self.isBackedUp = isBackedUp
        self.source = source
        self.status = status
    }

    public var hasSignals: Bool {
        !tags.isEmpty || !people.isEmpty || (faceCount ?? 0) > 0 || caption != nil || ocrText != nil
    }
}
