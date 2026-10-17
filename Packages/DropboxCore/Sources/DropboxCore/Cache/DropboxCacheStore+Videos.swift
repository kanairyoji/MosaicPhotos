#if canImport(UIKit)
import Foundation
import SwiftData

/// `DropboxCacheStore` の**動画の表**（`CachedDropboxVideo`・ADR-282）。
///
/// 写真の表とは読み手を分けてある（理由は `CachedDropboxVideo` の冒頭）。
/// 動画は写真よりずっと少ない前提で、全件を読む処理も素直に書いてある。
extension DropboxCacheStore {

    /// 表示用の動画の一覧（撮影日時の昇順＝写真の `cachedItems` と同じ並び）。
    func cachedVideos() -> [DropboxFileItem] {
        let descriptor = FetchDescriptor<CachedDropboxVideo>(
            sortBy: [SortDescriptor(\.captureDate, order: .forward)])
        guard let rows = try? modelContext.fetch(descriptor) else { return [] }
        return rows.map {
            DropboxFileItem(path: $0.path, name: $0.name, captureDate: $0.captureDate,
                            latitude: $0.latitude, longitude: $0.longitude,
                            video: DropboxVideoInfo(duration: $0.duration, byteSize: $0.byteSize))
        }
    }

    /// 動画の一覧の版を読む（fetch を伴わない）。
    func currentVideosRevision() -> Int { videosRevision }

    func cachedVideoCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<CachedDropboxVideo>())) ?? 0
    }

    func cachedVideoPaths() -> [String] {
        var descriptor = FetchDescriptor<CachedDropboxVideo>()
        descriptor.propertiesToFetch = [\.path]
        return ((try? modelContext.fetch(descriptor)) ?? []).map(\.path)
    }

    /// 差分の動画のぶんを当てる（`applyDelta` から呼ぶ・保存は呼び手がまとめて行う）。
    /// - Parameters:
    ///   - added: 動画だけ（`video` が付いたもの）。
    ///   - removed: 消えたパス（写真か動画かは分からないので、動画の表にあるものだけ消す）。
    func applyVideoDelta(added: [DropboxFileItem], removed: [String]) {
        var changed = false
        if !removed.isEmpty {
            // 消えたパスは写真のことが多い。1 件ずつ引かず、動画のパスを 1 回だけ読んで照らす。
            let known = Set(cachedVideoPaths())
            for path in removed where known.contains(path) {
                if let row = fetchCachedVideo(path: path) {
                    modelContext.delete(row)
                    changed = true
                }
            }
        }
        for item in added {
            guard let video = item.video else { continue }
            if let existing = fetchCachedVideo(path: item.path) {
                let hashChanged = existing.contentHash != item.contentHash
                // 撮影日時を訊いて確かめた行は、一覧の日付（アップロード時刻）で上書きしない（ADR-201 と同じ規則）。
                let keepsProbedDate = existing.probedAt != nil && !hashChanged
                let differs = existing.name != item.name
                    || hashChanged
                    || existing.byteSize != video.byteSize
                    || (!keepsProbedDate && existing.captureDate != item.captureDate)
                guard differs else { continue }   // 変わっていない行は書かない
                if hashChanged {
                    invalidate(path: item.path)   // サムネを捨てる
                    existing.probedAt = nil       // 中身が変わった＝長さも訊き直す
                    existing.duration = nil
                }
                existing.name = item.name
                existing.contentHash = item.contentHash
                existing.byteSize = video.byteSize
                if !keepsProbedDate { existing.captureDate = item.captureDate }
                existing.cachedAt = Date()
            } else {
                modelContext.insert(CachedDropboxVideo(
                    path: item.path, name: item.name, contentHash: item.contentHash,
                    captureDate: item.captureDate, byteSize: video.byteSize,
                    duration: video.duration, latitude: item.latitude, longitude: item.longitude))
            }
            changed = true
        }
        if changed { videosRevision &+= 1 }
    }

    /// まだ長さ・撮影日時を訊いていない動画のパス（新しい順・最大 `limit` 件）。
    func pathsNeedingVideoProbe(limit: Int) -> [String] {
        var descriptor = FetchDescriptor<CachedDropboxVideo>(
            predicate: #Predicate { $0.probedAt == nil },
            sortBy: [SortDescriptor(\.captureDate, order: .reverse)])
        descriptor.propertiesToFetch = [\.path]
        descriptor.fetchLimit = limit
        return ((try? modelContext.fetch(descriptor)) ?? []).map(\.path)
    }

    /// まだ訊いていない動画の数。
    func videoProbePendingCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<CachedDropboxVideo>(
            predicate: #Predicate { $0.probedAt == nil }))) ?? 0
    }

    /// 1 本ぶんの問い合わせ結果を記録する。**取れなかったことも記録する**（`probedAt` だけ進める）。
    func recordVideoProbe(path: String, duration: TimeInterval?, captureDate: Date?,
                          latitude: Double?, longitude: Double?, probedAt: Date = Date()) {
        guard let row = fetchCachedVideo(path: path) else { return }
        if let duration { row.duration = duration }
        if let captureDate { row.captureDate = captureDate }
        if let latitude { row.latitude = latitude }
        if let longitude { row.longitude = longitude }
        row.probedAt = probedAt
        try? modelContext.save()
        videosRevision &+= 1
    }

    /// テスト用: 一覧の対象の版を書き換える（写真だけの時代に見終えたルートを作る）。
    func setListingVersionForTesting(accountId: String, _ version: Int?) {
        guard let state = fetchSyncState(accountId: accountId) else { return }
        state.listingVersion = version
        try? modelContext.save()
    }

    private func fetchCachedVideo(path: String) -> CachedDropboxVideo? {
        let predicate = #Predicate<CachedDropboxVideo> { $0.path == path }
        return try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first
    }
}
#endif
