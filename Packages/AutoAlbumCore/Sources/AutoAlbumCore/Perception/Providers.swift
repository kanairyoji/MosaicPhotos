import Foundation

/// クラウド（Dropbox）写真1枚分の中立メタデータ。AutoAlbumCore を Dropbox 非依存に保つための値型。
public struct CloudPhotoMeta: Sendable, Equatable {
    public let path: String          // クラウド側の一意キー（Dropbox path）
    public let captureDate: Date?
    public let latitude: Double?
    public let longitude: Double?
    public let contentHash: String?  // 予備の同一性判定用

    public init(path: String, captureDate: Date?, latitude: Double?, longitude: Double?, contentHash: String?) {
        self.path = path
        self.captureDate = captureDate
        self.latitude = latitude
        self.longitude = longitude
        self.contentHash = contentHash
    }
}

/// クラウド写真一覧の供給元（実体はアプリ側で DropboxPhotoStore をラップ）。
public protocol CloudPhotoProvider: Sendable {
    func cloudPhotos() async -> [CloudPhotoMeta]
}

/// バックアップによる「ローカル localIdentifier → クラウド path」の対応を供給する。
/// ローカルとクラウドの同一写真を束ねる重複排除に使う。実体はアプリ側で BackupAssetRecord を読む。
public protocol BackupLinkProvider: Sendable {
    func localToCloudPath() async -> [String: String]
}

/// 「ローカル localIdentifier → 写っている人物名」の対応を供給する。
/// 人物アルバム（顔認識）インデックスを持つアプリ側（BackupKit）が実体を提供する。
/// 未提供（nil）でも自動アルバム生成は成立する（人物情報なしになるだけ）。
public protocol PeopleProvider: Sendable {
    func peopleByLocalIdentifier() async -> [String: [String]]
}

// MARK: - Perception seams（オンデバイス CLIP / VLM・アプリ側が実体を注入）

/// 写真1枚の知覚信号。検索は語彙ゼロのオープン語彙 CLIP に一本化したため、
/// バッチ知覚で持つのは **CLIP 画像埋め込みのみ**（OCR・固定語彙タグは廃止）。
public struct PhotoPerception: Sendable, Equatable {
    public let clipVector: Data?
    public init(clipVector: Data? = nil) {
        self.clipVector = clipVector
    }
}

/// 画像から CLIP 埋め込みを抽出する。実体は Core ML（アプリ側・MobileCLIP）。
/// 未提供（nil）なら意味検索は無効になるだけで他機能は動く。
/// `refKeys` は PhotoRef エンコード済みキー（"L-…"/"C-…"）。ローカル/クラウド双方を扱える。
public protocol PhotoPerceptionProvider: Sendable {
    /// 取り込み対象のうち、まだ埋め込みが無い refKey の埋め込みを計算して返す（キーは refKey）。
    func perceive(refKeys: [String]) async -> [String: PhotoPerception]
}

/// 検索文を CLIP テキスト埋め込みに変換する（英訳→テキストエンコーダ）。実体はアプリ側。
/// 未提供なら意味検索は無効（メタデータ検索のみ）。
public protocol TextEmbedder: Sendable {
    var isAvailable: Bool { get }
    func embed(_ text: String) async -> [Float]?
}

/// 任意言語の検索文を英語へ正規化する（CLIP は英語学習のため）。実体はアプリ側
/// （Foundation Models / Translation framework）。未提供なら原文をそのまま使う。
public protocol QueryTranslator: Sendable {
    func toEnglish(_ text: String) async -> String
}

/// 写真の CLIP 画像埋め込み（保存済み `clipVector`）から、**表示専用**の読めるタグを返す。
/// 実体はアプリ側（広めの英語キーワード集合に対する CLIP ゼロショット）。検索は語彙ゼロのまま、
/// これはフル画像表示のチップ用途に限る。未提供ならタグ無し。
public protocol LabelProvider: Sendable {
    func labels(forEmbedding clipVector: Data) async -> [String]
    /// 概念埋め込み等の遅延初期化を夜間に前倒しする（既定は何もしない）。
    func prewarm() async
    /// ラベル生成が**即応できる**か（概念埋め込みが構築済みか）。false のとき `labels(...)` を呼ぶと
    /// CLIP テキストタワーのロード（〜数十秒）＋約300語の構築が同期で走り得るので、フル画像 insight は
    /// これが true のときだけ CLIP ラベルを合成する（Vision タグは常に即表示）。既定 true。
    var isReady: Bool { get }
}

public extension LabelProvider {
    var isReady: Bool { true }
}


public extension LabelProvider {
    func prewarm() async {}
}
