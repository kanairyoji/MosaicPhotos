import Foundation

/// バックアップフォルダ内の `.mosaic/metadata.json` を表す値型。
/// `BackupEngine` がアップロード時に生成し、`DropboxPhotoStore` が読み込んで保持する。
/// ファイル本体（写真）は変更せず、People 情報などのメタデータを別ファイルで管理する。
public struct DropboxBackupMetadata: Codable, Sendable {

    /// パスごとのメタデータエントリ。
    /// v2（ADR-38）で追加したフィールドはすべて Optional＝v1 の JSON と相互に読める。
    /// 追加分は**端末から写真を削除すると再生成できない情報**（将来のオフロード前提の保全対象）。
    public struct Entry: Codable, Sendable {
        /// 人物名の一覧（v2: アプリの顔クラスタでユーザーが命名した人物。ユーザー入力＝再生成不能）。
        public var people: [String]
        /// ユーザーが手動で作成したアルバム名の一覧。
        public var albums: [String]
        /// PHAsset.isFavorite — お気に入りフラグ。
        public var isFavorite: Bool
        /// ISO 8601 形式の撮影日時。
        public var date: String?
        /// Dropbox content_hash（ファイル同一性の確認用）。
        public var contentHash: String?
        /// PHAsset.localIdentifier — ローカル⇔クラウドの対応表（オフロード時の refKey 移行・重複防止の鍵）。
        public var localIdentifier: String?
        /// PHAsset.location — EXIF に GPS の無い写真（スクショ・共有受信・手動設定）はここが唯一の出典。
        public var latitude: Double?
        public var longitude: Double?
        /// PHAsset.mediaSubtypes のスクリーンショット判定（クラウド側では再判定不能）。
        public var isScreenshot: Bool?
        /// アプリ生成の VLM キャプション（テキストで小さいため保全。VLM 未同梱端末への引き継ぎにもなる）。
        public var caption: String?
        /// オフロード前検証（contentHash 照合）に成功した日時（ISO 8601）。将来のオフロード機能用。
        public var verifiedAt: String?

        public init(
            people: [String],
            albums: [String] = [],
            isFavorite: Bool = false,
            date: String? = nil,
            contentHash: String? = nil,
            localIdentifier: String? = nil,
            latitude: Double? = nil,
            longitude: Double? = nil,
            isScreenshot: Bool? = nil,
            caption: String? = nil,
            verifiedAt: String? = nil
        ) {
            self.people     = people
            self.albums     = albums
            self.isFavorite = isFavorite
            self.date       = date
            self.contentHash = contentHash
            self.localIdentifier = localIdentifier
            self.latitude = latitude
            self.longitude = longitude
            self.isScreenshot = isScreenshot
            self.caption = caption
            self.verifiedAt = verifiedAt
        }
    }

    public var version: Int
    /// このファイルを最後に更新した日時（ISO 8601）。
    public var updatedAt: String
    /// key: Dropbox ファイルパス（小文字正規化済み） → value: Entry
    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.version = 1
        self.updatedAt = ISO8601DateFormatter().string(from: Date())
        self.entries = entries
    }

    /// 指定パスに対応する人物名リストを返す。パスは大文字小文字を無視して検索する。
    public func people(for path: String) -> [String] {
        entries[path.lowercased()]?.people ?? []
    }

    /// 既存エントリに新しいエントリをマージして返す（既存キーは上書き）。
    public func merging(_ other: [String: Entry]) -> DropboxBackupMetadata {
        var merged = self
        merged.entries.merge(other) { _, new in new }
        merged.updatedAt = ISO8601DateFormatter().string(from: Date())
        return merged
    }
}
