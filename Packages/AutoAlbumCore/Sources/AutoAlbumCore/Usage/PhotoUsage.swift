import Foundation
import MosaicSupport
import SwiftData

/// 写真ごとの利用カウンタ（閲覧・再生・共有）。お気に入りは PhotoKit（PHAsset.favorite）が
/// 持つため対象外。**別コンテナ "UsageV1"**（TagsV1/FacesV1 と同じパターン）＝
/// カウンタ機能の追加・変更で既存の AI データを壊さない。
@Model
final class PhotoUsageRecord {
    @Attribute(.unique) var refKey: String
    /// フル画面で閲覧した回数（ページに約 0.7 秒以上とどまったもの＝高速スワイプの通過は数えない）。
    var viewCount: Int
    /// 再生した回数（動画/Live Photo 対応時に使う・現状は常に 0）。
    var playCount: Int
    /// 共有した回数（共有シートで実際に共有アクションが完了したもの）。
    var shareCount: Int
    var lastViewedAt: Date?

    init(refKey: String) {
        self.refKey = refKey
        self.viewCount = 0
        self.playCount = 0
        self.shareCount = 0
    }
}

/// UI 受け渡し用の値型。
public struct PhotoUsageCounts: Sendable, Equatable {
    public var viewCount: Int
    public var playCount: Int
    public var shareCount: Int

    public init(viewCount: Int = 0, playCount: Int = 0, shareCount: Int = 0) {
        self.viewCount = viewCount
        self.playCount = playCount
        self.shareCount = shareCount
    }
}

/// カウンタの種別（エンジン公開 API 用）。
public enum PhotoUsageEventKind: String, Sendable {
    case view, play, share
}

/// 利用カウンタの @ModelActor ストア。⚠️ 本番はオフメイン生成（TagStore と同じ）。
@ModelActor
actor UsageStore {
    private static let log = LogChannel(subsystem: "com.mosaicphotos.AutoAlbum", label: "Usage")

    static func makeContainer(isStoredInMemoryOnly: Bool = false) -> ModelContainer {
        let schema = Schema([PhotoUsageRecord.self])
        if isStoredInMemoryOnly {
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return (try? ModelContainer(for: schema, configurations: [memory])) ?? (try! ModelContainer(for: schema))
        }
        return resilientModelContainer(name: "UsageV1", schema: schema) { Self.log.error($0) }
    }

    init(isStoredInMemoryOnly: Bool = false) {
        self.init(modelContainer: Self.makeContainer(isStoredInMemoryOnly: isStoredInMemoryOnly))
    }

    /// カウンタを 1 進める（レコードが無ければ作成）。
    func increment(_ kind: PhotoUsageEventKind, refKey: String) {
        let key = refKey
        var d = FetchDescriptor<PhotoUsageRecord>(predicate: #Predicate { $0.refKey == key })
        d.fetchLimit = 1
        let record = (try? modelContext.fetch(d).first) ?? {
            let r = PhotoUsageRecord(refKey: key)
            modelContext.insert(r)
            return r
        }()
        switch kind {
        case .view:
            record.viewCount += 1
            record.lastViewedAt = Date()
        case .play:
            record.playCount += 1
        case .share:
            record.shareCount += 1
        }
        try? modelContext.save()
    }

    /// 指定 refKey 群のカウンタ（情報パネル用）。レコードが無い写真は結果に含めない（＝全 0）。
    func counts(forRefKeys keys: [String]) -> [String: PhotoUsageCounts] {
        guard !keys.isEmpty else { return [:] }
        let set = keys
        let records = (try? modelContext.fetch(
            FetchDescriptor<PhotoUsageRecord>(predicate: #Predicate { set.contains($0.refKey) }))) ?? []
        var out: [String: PhotoUsageCounts] = [:]
        for r in records {
            out[r.refKey] = PhotoUsageCounts(viewCount: r.viewCount, playCount: r.playCount,
                                             shareCount: r.shareCount)
        }
        return out
    }

    func reset() {
        try? modelContext.delete(model: PhotoUsageRecord.self)
        try? modelContext.save()
    }
}
