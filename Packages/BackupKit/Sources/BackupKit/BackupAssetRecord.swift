import Foundation
import SwiftData

/// バックアップ済み写真の記録。バックアップ実行のたびに追記される。
/// `dropboxPath` が Dropbox 側の安定キー。
/// `localIdentifier` は写真を iPhone から削除した後は無効になるが記録は保持する。
@Model
public final class BackupAssetRecord {
    /// Dropbox 上のファイルパス（小文字正規化済み）。主キー。
    @Attribute(.unique) public var dropboxPath: String
    /// PHAsset.localIdentifier。削除後は参照不能になるが、バックアップ時の記録として保持する。
    public var localIdentifier: String?
    /// **同じファイルを指す、ほかの端末写真**の localIdentifier（ADR-278 追補 2）。
    ///
    /// 記録はパスにつき 1 件で、`localIdentifier` は「最後に確かめた写真」に付け替わる。中身も名前も
    /// 同じ重複写真が 2 枚あると、片方は記録を失い、共有が待つ写真（記録の無いメンバー）として
    /// **毎回上げ直されていた**——上げると 409 で持ち主がもう片方へ移り、次はそちらが待つ。
    /// 付け替えるとき前の持ち主をここへ残し、「済み」と共有の解決はこちらも見る。
    /// ⚠️ 台帳なので**省略可能な列の追加**だけで進める（ADR-186）。
    public var otherLocalIdentifiers: [String]?
    public var filename: String
    public var creationDate: Date?
    /// Dropbox content_hash（バックアップ完了後に設定）。
    public var contentHash: String?
    /// バックアップ時点の People アルバムから取得した人物名。
    public var people: [String]
    /// バックアップ時点のユーザー作成アルバム名。
    public var albums: [String]
    /// PHAsset.isFavorite — お気に入りフラグ。
    public var isFavorite: Bool
    public var backedUpAt: Date

    public init(
        dropboxPath: String,
        localIdentifier: String?,
        filename: String,
        creationDate: Date?,
        contentHash: String?,
        people: [String],
        albums: [String],
        isFavorite: Bool
    ) {
        self.dropboxPath     = dropboxPath.lowercased()
        self.localIdentifier = localIdentifier
        self.filename        = filename
        self.creationDate    = creationDate
        self.contentHash     = contentHash
        self.people          = people
        self.albums          = albums
        self.isFavorite      = isFavorite
        self.backedUpAt      = Date()
    }
}
