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

    /// アカウントと保存先ごとに**別のキュー**にする。
    ///
    /// ⚠️ 共通のファイル 1 つだと、アカウントや保存先を切り替えたときに、
    /// **前の保存先向けのメタデータ（人物名・位置・アルバム）を現在の保存先へ送る**
    /// （レビュー指摘）。名前空間は「アカウント指紋＋バックアップルート」から作る。
    init(account: String?, folder: String) {
        let seed = "\(account ?? "-")|\(folder.lowercased())"
        var hash: UInt64 = 5381
        for byte in Array(seed.utf8) { hash = hash &* 33 &+ UInt64(byte) }
        self.init(filename: String(format: "BackupPendingMetadata-%016llx.json", hash))
    }

    init(filename: String = "BackupPendingMetadata.json") {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil,
                                                 create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = base.appendingPathComponent(filename)
    }

    /// テスト用（書けない場所での挙動を確かめる）。
    init(directory: URL, filename: String) {
        fileURL = directory.appendingPathComponent(filename)
    }

    func load() -> Payload {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [:] }
        return payload
    }

    /// - Returns: **保存できたか**。false のときはバックアップを正常完了扱いにしてはいけない
    ///   （写真本体は進捗台帳に載って次回の対象から外れるため、送信失敗＋保存失敗が重なると
    ///   人物・アルバム・位置情報が永久に欠落する・レビュー指摘）。
    @discardableResult
    func save(_ payload: Payload) -> Bool {
        guard !payload.isEmpty else {
            // 空＝保留なし。ファイルが無い場合も成功として扱う。
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                return true
            } catch {
                BackupLogger.error("PendingMetadataStore: could not clear queue — \(error)")
                return false
            }
        }
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            BackupLogger.error("PendingMetadataStore: save failed — \(error)")
            return false
        }
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
