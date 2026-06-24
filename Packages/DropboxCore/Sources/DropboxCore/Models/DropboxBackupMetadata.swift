import Foundation

/// バックアップフォルダ内の `.mosaic/metadata.json` を表す値型。
/// `BackupEngine` がアップロード時に生成し、`DropboxPhotoStore` が読み込んで保持する。
/// ファイル本体（写真）は変更せず、People 情報などのメタデータを別ファイルで管理する。
public struct DropboxBackupMetadata: Codable, Sendable {

    /// パスごとのメタデータエントリ。
    public struct Entry: Codable, Sendable {
        /// Photos.app のピープルアルバムから取得した人物名の一覧。
        public var people: [String]
        /// ユーザーが手動で作成したアルバム名の一覧。
        public var albums: [String]
        /// PHAsset.isFavorite — お気に入りフラグ。
        public var isFavorite: Bool
        /// ISO 8601 形式の撮影日時。
        public var date: String?
        /// Dropbox content_hash（ファイル同一性の確認用）。
        public var contentHash: String?

        public init(
            people: [String],
            albums: [String] = [],
            isFavorite: Bool = false,
            date: String? = nil,
            contentHash: String? = nil
        ) {
            self.people     = people
            self.albums     = albums
            self.isFavorite = isFavorite
            self.date       = date
            self.contentHash = contentHash
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
