import CoreLocation
import Foundation
import MosaicSupport

public struct DropboxFileItem: Identifiable, Equatable, Hashable {
    public let path: String
    public let name: String
    /// Dropbox `content_hash` from `list_folder`. Used by `DropboxCacheStore` to
    /// detect remote changes and invalidate cached binaries cheaply.
    public let contentHash: String?
    /// 撮影日時。`media_info.time_taken` が取れればそれ、無ければ `client_modified`。
    /// 無意味な日付（EXIF 欠落・0 値・1970/1980 等）は init で nil＝日時不明に落とす。
    public let captureDate: Date?
    /// 撮影地の緯度・経度（`list_folder` の `include_media_info` で取得。pending 時は nil）。
    public let latitude: Double?
    public let longitude: Double?
    /// アプリ側お気に入り（Dropbox に favorite 概念は無いので、cloudPath 単位でアプリが管理する）。
    /// `DropboxPhotoStore` が items 構築時に永続集合から**刻印**する（既定 false）。
    public let isFavorite: Bool
    /// 動画なら、その付帯情報（nil＝写真）。**動画かどうかはこれの有無だけで決まる**（ADR-282）。
    ///
    /// ⚠️ 参照型（8 バイト）にしてある。表示用の一覧は 10 万件規模で常駐し、写真では全部 nil なので、
    /// 長さ・大きさを値で持つと写真のぶんまで 1 件 20 バイト前後ずつ膨らむ。
    /// ⚠️ 付けるのは一覧の解析（`DeltaPageParser`）と動画の表（`CachedDropboxVideo`）からの復元だけ。
    public let video: DropboxVideoInfo?

    /// 動画か（`video` の有無）。
    public var isVideo: Bool { video != nil }

    public init(
        path: String,
        name: String,
        contentHash: String? = nil,
        captureDate: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        isFavorite: Bool = false,
        video: DropboxVideoInfo? = nil
    ) {
        self.path = path
        self.name = name
        self.contentHash = contentHash
        // 生成点（同期パース・キャッシュ復元）でまとめてサニタイズする（入口で一度だけ）。
        self.captureDate = CaptureDate.meaningful(captureDate)
        self.latitude = latitude
        self.longitude = longitude
        self.isFavorite = isFavorite
        self.video = video
    }

    /// お気に入りだけ差し替えた複製（`DropboxPhotoStore` の刻印・トグルで使う）。
    public func withFavorite(_ favorite: Bool) -> DropboxFileItem {
        DropboxFileItem(path: path, name: name, contentHash: contentHash, captureDate: captureDate,
                        latitude: latitude, longitude: longitude, isFavorite: favorite, video: video)
    }

    /// 撮影日を差し替えた複製。
    /// ⚠️ Dropbox 側の撮影日は `time_taken ?? client_modified` で、EXIF から media_info が
    /// 付かない写真では**アップロード時刻**になる。アプリの台帳（バックアップ記録）が元の
    /// 撮影日を持っている場合は、そちらを正として表示側で差し替える（ADR-128 追補）。
    public func withCaptureDate(_ date: Date?) -> DropboxFileItem {
        DropboxFileItem(path: path, name: name, contentHash: contentHash, captureDate: date,
                        latitude: latitude, longitude: longitude, isFavorite: isFavorite, video: video)
    }

    public var id: String { path }

    /// 緯度・経度が揃っていれば座標を返す。
    public var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public var nameWithoutExtension: String {
        (name as NSString).deletingPathExtension
    }
}

/// Dropbox の動画の付帯情報（`DropboxFileItem.video`）。
///
/// 値の意味で比べる（参照の同一性ではない）——一覧の指紋・差分の判定に使われるため。
public final class DropboxVideoInfo: Hashable, Sendable {
    /// 再生時間（秒）。`files/get_metadata` の `media_info` で訊くまでは nil
    /// （一覧系 API は `media_info` を返さない・ADR-201）。
    public let duration: TimeInterval?
    /// ファイルの大きさ（バイト・`list_folder` の `size`）。モバイル通信で流す前に見せる。
    public let byteSize: Int64?

    public init(duration: TimeInterval?, byteSize: Int64?) {
        self.duration = duration
        self.byteSize = byteSize
    }

    public static func == (lhs: DropboxVideoInfo, rhs: DropboxVideoInfo) -> Bool {
        lhs.duration == rhs.duration && lhs.byteSize == rhs.byteSize
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(duration)
        hasher.combine(byteSize)
    }
}
