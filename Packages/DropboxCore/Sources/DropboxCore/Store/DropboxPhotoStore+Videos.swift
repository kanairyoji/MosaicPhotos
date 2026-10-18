#if canImport(UIKit)
import AVFoundation
import CoreLocation
import Foundation
import ImageCacheKit
import MosaicSupport
import UIKit

/// `DropboxPhotoStore` の**動画**（ADR-282）。再生・サムネ・長さの問い合わせ・共有。
///
/// ## スマホで使う前提の作り
/// - **丸ごと落とさない**。再生は一時リンク（`files/get_temporary_link`）を `AVPlayer` に渡して
///   流す——要るところだけ範囲指定で取りに行くので、途中でやめれば残りは通信しない。
///   ディスクのキャッシュにも保存しない（1 本で数百 MB になり得る）。
/// - 自動で流してよいかは**先読みと同じ規則**（`NetworkStateMonitor.speculativeFetchAllowed`＝
///   設定の通信ポリシー × 低電力モード）。モバイル通信では大きさを見せてタップを待つ
///   （判断は `VideoPlaybackView`、ここは大きさを渡すだけ）。
/// - フル画像・EXIF・カバーの経路は動画を**受け付けない**（`+Images` の入口で弾く）。
///   ページを送るたびの先読みが、隣の動画を丸ごと落とさないように。
extension DropboxPhotoStore {

    // MARK: - 一時リンク

    /// 動画を流す一時リンク。控えがあり期限まで余裕があればそれを使う。
    func temporaryLink(for path: String) async -> URL? {
        // 期限（4 時間）より早めに捨てる（再生の途中で切れないように）。
        if let cached = temporaryLinks[path], cached.expires > Date() { return cached.url }
        guard let stamp = imageStamp() else { return nil }
        struct Arg: Encodable { let path: String }
        struct Reply: Decodable { let link: String }
        guard let body = try? JSONEncoder().encode(Arg(path: path)) else { return nil }
        let data: Data
        do {
            data = try await apiClient.rpc(url: DropboxInternalConstants.getTemporaryLinkURL,
                                           jsonBody: body)
        } catch {
            if RequestCancellation.matches(error) { return nil }
            DropboxLogger.error("temporaryLink() failed — \(error.localizedDescription)")
            return nil
        }
        // 待っている間にアカウントが変わったら使わない（別人のファイルを流さない・ADR-174）。
        guard Self.shouldDeliverImage(captured: stamp, currentGeneration: currentLoadGeneration,
                                      currentAccountId: auth.credential?.accountId),
              let reply = try? JSONDecoder().decode(Reply.self, from: data),
              let url = URL(string: reply.link) else { return nil }
        temporaryLinks[path] = (url, Date().addingTimeInterval(3 * 60 * 60))
        return url
    }

    // MARK: - 再生

    /// 再生する `AVPlayerItem`（写真・取得できないときは nil）。呼ぶたびに新しいものを返す。
    public func playerItem(for item: DropboxFileItem) async -> AVPlayerItem? {
        guard item.isVideo, let url = await temporaryLink(for: item.path) else { return nil }
        return AVPlayerItem(asset: AVURLAsset(url: url))
    }

    /// Dropbox の Web で開く URL（このアプリで再生できない形式のための逃げ道）。
    /// Dropbox のアプリが入っていれば、ユニバーサルリンクでそちらが開く。
    public func webPreviewURL(for item: DropboxFileItem) -> URL? {
        Self.webPreviewURL(path: item.path, name: item.name)
    }

    /// `https://www.dropbox.com/home/<親フォルダ>?preview=<名前>`（純ロジック・テスト対象）。
    nonisolated static func webPreviewURL(path: String, name: String) -> URL? {
        let parent = (path as NSString).deletingLastPathComponent
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.dropbox.com"
        components.path = "/home" + (parent == "/" ? "" : parent)
        components.queryItems = [URLQueryItem(name: "preview", value: name)]
        return components.url
    }

    // MARK: - サムネ

    /// 動画のサムネを**手元で作る**（Dropbox がサムネを返さなかったとき）。
    ///
    /// 一時リンクから先頭付近の 1 コマだけを取る（`AVAssetImageGenerator` は要るところだけ
    /// 範囲指定で読む）。作れたらサムネのキャッシュへ入れる＝次からは通信しない。
    /// iOS が読めない形式は作れないので、この起動の間は二度と試さない。
    func generatedVideoThumbnail(for item: DropboxFileItem) async -> UIImage? {
        guard item.isVideo, !videoThumbnailUnavailable.contains(item.path) else { return nil }
        await videoThumbnailLimiter.acquire()
        defer { Task { await videoThumbnailLimiter.release() } }
        // 待っている間に別の要求が作っていれば、それを使う。
        if let cached = await cache.thumbnail(for: item.path) { return cached }
        guard !Task.isCancelled, let url = await temporaryLink(for: item.path) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        let t0 = PerfTrace.nowNs()
        do {
            // 先頭のコマは黒いことが多いので少しだけ進める（短い動画でも範囲内に収まる値）。
            let (cgImage, _) = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
            let image = UIImage(cgImage: cgImage)
            await cache.storeThumbnail(image, for: item.path)
            Diagnostics.mark("video: cloud thumbnail generated in \(Int(PerfTrace.msSince(t0)))ms")
            return image
        } catch {
            if Task.isCancelled { return nil }   // スクロールで外れただけ＝失敗ではない
            videoThumbnailUnavailable.insert(item.path)
            Diagnostics.mark("video: cloud thumbnail unavailable (\((item.name as NSString).pathExtension))")
            return nil
        }
    }

    // MARK: - 長さ・撮影日時の問い合わせ

    /// まだ訊いていない動画の長さ・撮影日時・撮影地を、少しずつ埋める。
    ///
    /// 一覧系 API は `media_info` を返さない（ADR-201）ので、1 本ずつ `get_metadata` を訊く。
    /// 動画は写真より桁違いに少ない前提で、写真の穴埋め（`fillMissingCaptureDates`）とは別に回す
    /// ——写真の残り（10 万件規模）の後ろに並ぶと、グリッドに長さが出るのが何日も先になる。
    /// - Returns: **記録できた**本数（0＝残っていない、または通信できなかった）。
    ///   ⚠️ 訊いた本数を返すと、通信できない間は同じ動画を延々と訊き直す輪になる。
    @discardableResult
    public func fillMissingVideoInfo(limit: Int = 12) async -> Int {
        // 「まだ分からない」と返った動画は、控えの時刻まで候補から外す（同じ起動の中で訊き直し続けない）。
        let now = Date()
        videoProbeRetryAfter = videoProbeRetryAfter.filter { $0.value > now }
        let waiting = Set(videoProbeRetryAfter.keys)
        let paths = Array(await cache.pathsNeedingVideoProbe(limit: limit + waiting.count)
            .filter { !waiting.contains($0) }.prefix(limit))
        guard !paths.isEmpty else { return 0 }
        var recorded = 0
        for chunk in stride(from: 0, to: paths.count, by: 4).map({
            Array(paths[$0..<min($0 + 4, paths.count)])
        }) {
            recorded += await withTaskGroup(of: Bool.self) { group in
                for path in chunk {
                    group.addTask { [weak self] in await self?.probeVideoInfo(path: path) ?? false }
                }
                var n = 0
                for await ok in group where ok { n += 1 }
                return n
            }
            if Task.isCancelled { break }
        }
        if recorded > 0 { refreshItemsFromCacheSoon() }
        Diagnostics.mark("dropbox: video info probed=\(recorded)/\(paths.count) "
                         + "notReady=\(videoProbeRetryAfter.count) "
                         + "remaining=\(await cache.videoProbePendingCount())")
        return recorded
    }

    /// 長さの分からない動画があれば、**前面にいる間だけ**順に訊いていく（1 本の輪だけ）。
    ///
    /// ⚠️ 写真の撮影日の穴埋めのように `.cloudTrickle`（充電中など）を待たせない。
    /// 1 本 1KB 程度の問い合わせで、待たせるとグリッドの長さがいつまでも出ない。
    /// 背面では走らせない（見ている人がいない・次に前面へ来たとき一覧の反映から再開する）。
    func startVideoInfoFillIfNeeded() {
        guard videoInfoFillTask == nil, BackgroundYield.scenePhase == .active else { return }
        videoInfoFillTask = Task { [weak self] in
            while !Task.isCancelled, BackgroundYield.scenePhase == .active,
                  let self, await self.fillMissingVideoInfo() > 0 {}
            self?.videoInfoFillTask = nil
        }
    }

    /// - Returns: 記録したか（通信できなかった回・まだ分からない回は false＝後で訊き直す）。
    private func probeVideoInfo(path: String) async -> Bool {
        struct Arg: Encodable { let path: String; let include_media_info = true }
        guard let body = try? JSONEncoder().encode(Arg(path: path)) else { return false }
        let data: Data
        do {
            data = try await apiClient.rpc(url: DropboxInternalConstants.getMetadataURL,
                                           jsonBody: body)
        } catch DropboxAPIClient.APIError.http(let status, let errBody)
                    where status == 409 && errBody.contains("not_found") {
            // 「そこに無い」は訊き直しても変わらない（写真の穴埋めと同じ扱い）。
            await cache.recordVideoProbe(path: path, duration: nil, captureDate: nil,
                                         latitude: nil, longitude: nil)
            return true
        } catch {
            return false   // 通信できなかった回は記録しない（次回訊き直す）
        }
        let metadata: DropboxMediaInfo.MediaMetadata?
        switch Self.videoProbeReply(data) {
        case .info(let m): metadata = m
        case .noInfo: metadata = nil
        case .notReady:
            // ⚠️ 記録しない（記録すると `probedAt == nil` の候補から外れ、二度と訊かない）。
            videoProbeRetryAfter[path] = Date().addingTimeInterval(Self.videoProbeRetryInterval)
            return false
        }
        let captureDate = CaptureDate.meaningful(
            metadata?.time_taken.flatMap { DropboxPhotoStore.iso8601.date(from: $0) })
        await cache.recordVideoProbe(path: path, duration: metadata?.durationSeconds,
                                     captureDate: captureDate,
                                     latitude: metadata?.location?.latitude,
                                     longitude: metadata?.location?.longitude)
        return true
    }

    /// 「まだ分からない」と返った動画を、同じ起動の中で次に訊くまでの間隔。
    static let videoProbeRetryInterval: TimeInterval = 10 * 60

    /// `get_metadata` の応答の 3 つの形（純ロジック・テスト対象）。
    enum VideoProbeReply: Equatable {
        /// 情報が取れた。
        case info(DropboxMediaInfo.MediaMetadata)
        /// Dropbox が「情報は無い」と言い切った（`media_info` が無い）。訊き直しても変わらない。
        case noInfo
        /// まだ分からない（`pending`＝解析中、または応答を読めなかった）。後で訊けば取れ得る。
        case notReady
    }

    nonisolated static func videoProbeReply(_ data: Data) -> VideoProbeReply {
        struct Meta: Decodable { let media_info: DropboxMediaInfo? }
        guard let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return .notReady }
        guard let info = meta.media_info else { return .noInfo }
        if info.tag == "pending" { return .notReady }
        return info.metadata.map(VideoProbeReply.info) ?? .noInfo
    }

    // MARK: - 共有

    /// 共有に渡す動画ファイル（元のファイル名）。一時リンクから**ファイルへ直接**落とす
    /// ——`Data` でメモリに載せない（数百 MB になり得る）。サムネ・フル画像のキャッシュにも入れない。
    public func videoFileForSharing(_ item: DropboxFileItem, destination: URL) async -> Bool {
        guard item.isVideo, let url = await temporaryLink(for: item.path) else { return false }
        DropboxActivityMonitor.shared.beginFullImage()
        defer { DropboxActivityMonitor.shared.endFullImage() }
        do {
            let (downloaded, response) = try await URLSession.dropboxDefault.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? FileManager.default.removeItem(at: downloaded)
                return false
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: downloaded, to: destination)
            return true
        } catch {
            if !RequestCancellation.matches(error) {
                DropboxLogger.error("videoFileForSharing() failed — \(error.localizedDescription)")
            }
            return false
        }
    }
}
#endif
