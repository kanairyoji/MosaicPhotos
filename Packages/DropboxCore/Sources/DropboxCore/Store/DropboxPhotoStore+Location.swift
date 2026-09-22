#if canImport(UIKit)
import CoreLocation
import Foundation
import MosaicSupport

/// `DropboxPhotoStore` の **media_info 解決**（撮影日時・撮影地）。本体宣言は `DropboxPhotoStore.swift`。
///
/// ## Dropbox の制約（ADR-201・一次情報で確認）
/// `media_info` は **`list_folder` / `list_folder/continue` / `get_thumbnail_batch` では
/// 返ってこない**（2019-12-02 以降）。したがって一覧から得られる日付は `client_modified`＝
/// **アップロード時刻**であって撮影日時ではない。撮影日時と撮影地の唯一の出典は
/// `files/get_metadata` を **1 枚ずつ**叩くことで、1 往復あたり数秒かかる。
///
/// だからここでの原則は 2 つ。
/// - **1 回の往復で両方取る**（撮影日時と撮影地は同じ応答に入っている）。
/// - **無かったことも記録する**（`captureDateProbedAt`）。EXIF の無い写真は何度訊いても
///   無いので、記録しないと 6.8 万枚ぶんの往復を毎回繰り返す（CLAUDE.md 性能原則 3）。
extension DropboxPhotoStore {

    /// 1 枚ぶんの `media_info` を取りに行き、**撮影日時と撮影地の両方**をキャッシュへ記録する。
    /// - Returns: 取れた値（どちらも nil＝この写真に EXIF が無い。それも記録済み）。
    @discardableResult
    public func probeMediaInfo(for path: String) async
        -> (captureDate: Date?, coordinate: CLLocationCoordinate2D?) {
        struct Arg: Encodable { let path: String; let include_media_info = true }
        guard let body = try? JSONEncoder().encode(Arg(path: path)) else { return (nil, nil) }
        let data: Data
        do {
            data = try await apiClient.rpc(url: DropboxInternalConstants.getMetadataURL,
                                           jsonBody: body)
        } catch DropboxAPIClient.APIError.http(let status, let errBody)
                    where status == 409 && errBody.contains("not_found") {
            // ⚠️ **「そこに無い」は訊き直しても変わらない**（diagnostics-82）。
            // 通信できなかった回と同じ「記録しない」にすると、消えた写真のキャッシュ行が
            // 候補の先頭に居座って**同じ 12 件を永久に叩き続ける**。実機では 63 回連続で
            // remaining=80,172 のまま動かず、734 回の 409 を費やして本来の穴埋めが
            // 1 枚も進まなかった。訊いた事実だけ記録して先へ進める。
            await cache.recordCaptureDateProbe(path: path, captureDate: nil,
                                               latitude: nil, longitude: nil)
            return (nil, nil)
        } catch {
            return (nil, nil)   // 通信できなかった回は**記録しない**（次回訊き直す）
        }

        struct Meta: Decodable { let media_info: DropboxMediaInfo? }
        let metadata = (try? JSONDecoder().decode(Meta.self, from: data))?.media_info?.metadata
        let coordinate = metadata?.location.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        // ⚠️ 未来の日付・1970/1980 等の無意味な値は弾く（`DropboxFileItem` と同じ規則）。
        let captureDate = CaptureDate.meaningful(
            metadata?.time_taken.flatMap { DropboxPhotoStore.iso8601.date(from: $0) })
        await cache.recordCaptureDateProbe(path: path, captureDate: captureDate,
                                           latitude: coordinate?.latitude,
                                           longitude: coordinate?.longitude)
        return (captureDate, coordinate)
    }

    /// 撮影地の座標。同期時に取れていれば即返し、無ければ 1 往復して補完・保存する。
    public func location(for item: DropboxFileItem) async -> CLLocationCoordinate2D? {
        if let coordinate = item.coordinate { return coordinate }
        return await probeMediaInfo(for: item.path).coordinate
    }

    /// ネット取得を伴わない座標。同期時に取れていれば返し、無ければ nil（get_metadata は叩かない）。
    /// フル表示の場所ラベル用：開くたびの 4〜6s の get_metadata 往復を避ける。
    public func cachedLocation(for item: DropboxFileItem) async -> CLLocationCoordinate2D? {
        item.coordinate
    }

    // MARK: - 撮影日時の穴埋め（トリクル）

    /// **まだ訊いていない写真の撮影日時を、少しずつ埋める**（ADR-201）。
    ///
    /// 1 枚 1 往復なので一度に全部はやらない。呼び出し側（`HomeView` の定期ループ）が
    /// `BackgroundYield.allows(.cloudTrickle)` を満たすときだけ、この関数を繰り返し呼ぶ。
    ///
    /// ⚠️ **往復は重ねる**（CLAUDE.md 性能原則 1）。1 枚ずつ直列に待つと待ち時間がそのまま
    /// 積み上がる（6.8 万枚 × 数秒）。互いに独立した RPC なので少数を並行させる。
    /// 並行数は Dropbox のレート制限に配慮して小さく固定する（サムネのバッチャと同じ考え方）。
    /// - Returns: 実際に問い合わせた枚数（0＝もう残っていない）。
    @discardableResult
    public func fillMissingCaptureDates(limit: Int = 12) async -> Int {
        let paths = await cache.pathsNeedingCaptureDateProbe(limit: limit)
        guard !paths.isEmpty else { return 0 }
        let concurrency = 4
        var probed = 0
        var index = 0
        while index < paths.count {
            let slice = Array(paths[index..<min(index + concurrency, paths.count)])
            index += slice.count
            await withTaskGroup(of: Void.self) { group in
                for path in slice {
                    group.addTask { [weak self] in _ = await self?.probeMediaInfo(for: path) }
                }
            }
            probed += slice.count
            if Task.isCancelled { break }
        }
        // 日付が変われば並び順も変わる＝一覧を作り直す（キャッシュの版で判断される）。
        refreshItemsFromCacheSoon()
        Diagnostics.mark("dropbox: capture dates probed=\(probed) "
                         + "remaining=\(await cache.captureDateProbePendingCount())")
        return probed
    }

    /// パスの束 → **EXIF の撮影日時**（アップロード時刻は含まない・ADR-218）。
    /// 顔の撮影日（時期グループ・赤ちゃんの時期の決まり）はこれを使う。ネットには出ない。
    public func exifCaptureDates(paths: [String]) async -> [String: Date] {
        await cache.exifCaptureDates(paths: paths)
    }

    /// ISO 8601（`time_taken` は "2015-05-12T15:50:38Z" 形式）。
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
#endif
