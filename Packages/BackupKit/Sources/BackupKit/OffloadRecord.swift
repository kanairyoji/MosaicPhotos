import Foundation
import SwiftData

/// オフロード台帳（ADR-39）: アプリが**検証つきで端末から削除した**写真の記録。
///
/// 端末アルバムの合成表示は「アルバムにあったのに端末に無い写真」を無条件にクラウドから
/// 補完するのではなく、**この台帳にある写真だけ**を補完する。ユーザーが写真アプリで
/// 意図的に削除した写真を誤って蘇らせないための区別が本質（設計説明の第 4 項）。
///
/// - 書き込み: 将来のオフロード機能（contentHash 照合 → 削除 → 記録）。現時点で削除機能は
///   無いので通常は空。復元（端末へ再取り込み）時にはエントリを削除する。
/// - 再構築: 機種変更・再インストール時は metadata v2 の `offloadedAt` マーカー付きエントリ
///   から復元する（`BackupMetadataPlanning.offloadCandidates`）。
@Model
public final class OffloadRecord {
    /// オフロード時点の PHAsset.localIdentifier（主キー・以後は端末で解決不能になる）。
    @Attribute(.unique) public var localIdentifier: String
    /// クラウド代替の Dropbox パス（小文字正規化済み）。
    public var dropboxPath: String
    /// オフロード時点の所属アルバム名（端末アルバム合成表示の逆引きキー）。
    public var albums: [String]
    /// 撮影日時（合成表示の時系列ソート用）。
    public var captureDate: Date?
    /// 削除前検証に使った Dropbox content_hash。
    public var contentHash: String?
    public var offloadedAt: Date

    public init(localIdentifier: String, dropboxPath: String, albums: [String],
                captureDate: Date?, contentHash: String?, offloadedAt: Date = Date()) {
        self.localIdentifier = localIdentifier
        self.dropboxPath = dropboxPath
        self.albums = albums
        self.captureDate = captureDate
        self.contentHash = contentHash
        self.offloadedAt = offloadedAt
    }
}
