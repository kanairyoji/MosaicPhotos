import DropboxCore
import Foundation
import MosaicSupport

/// 送信できなかったメタデータの**再送キュー**（永続）。
///
/// ⚠️ なぜ要るか: 写真の実体アップロードが成功すると、その ID は台帳（progressStore）と
/// SwiftData に記録され、以後 pending に入らない。つまりメタデータ（人物名・アルバム・
/// 位置情報）の書き込みに失敗しても、**次回の実行では作り直されない**——同じ写真が
/// 二度と対象にならないため。放置すると欠落が永久化する（レビュー指摘）。
/// 失敗分をここに残し、次回の実行で先に送り直す。
///
/// 置き場所は Application Support（Caches だと OS に消され得る＝欠落が確定してしまう）。
struct PendingMetadataStore {

    /// 保存形式: シャード名 → (Dropbox パス → エントリ)。
    typealias Payload = [String: [String: DropboxBackupMetadata.Entry]]

    private let fileURL: URL

    init(filename: String = "BackupPendingMetadata.json") {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil,
                                                 create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = base.appendingPathComponent(filename)
    }

    func load() -> Payload {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [:] }
        return payload
    }

    func save(_ payload: Payload) {
        guard !payload.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 保留分を取り込み、今回の分と統合する（同じパスは今回の値を優先）。
    static func merged(pending: Payload, adding: Payload) -> Payload {
        var out = pending
        for (shard, entries) in adding {
            out[shard] = (out[shard] ?? [:]).merging(entries) { _, new in new }
        }
        return out
    }

    /// 保留件数（診断ログ用）。
    static func entryCount(_ payload: Payload) -> Int {
        payload.values.reduce(0) { $0 + $1.count }
    }
}
