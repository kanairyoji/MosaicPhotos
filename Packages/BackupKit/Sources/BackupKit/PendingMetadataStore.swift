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

    /// 追記ジャーナル（1 行 1 エントリ）。**アップロード成功のたびに 1 行だけ**足す。
    ///
    /// ⚠️ なぜ本体（JSON 全体）に書かないか: 本体は毎回まるごと書き直すので、
    /// 1 枚ごとに保存すると枚数の 2 乗に比例する（1 万枚で現実的でない）。
    /// 追記なら 1 枚あたり一定コストで、途中終了しても**それまでの全行が残る**。
    private var journalURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("jsonl")
    }

    /// ジャーナル 1 行の形。
    private struct JournalLine: Codable {
        let shard: String
        let path: String
        let entry: DropboxBackupMetadata.Entry
    }

    /// 1 件を**その場で永続化**する（写真の完了記録より先に呼ぶ）。
    ///
    /// ⚠️ 順序が肝（ADR-171）。完了記録を先に保存すると、その間に中断されたとき
    /// 「写真は済み・メタデータは無い」状態が確定する——写真本体は進捗台帳に載って
    /// 次回の対象から外れるので、**人物名・アルバム・位置情報は二度と作られない**。
    /// - Returns: 書けたか。false なら呼び出し側は**完了記録を保存してはいけない**。
    @discardableResult
    func appendEntry(shard: String, path: String,
                     entry: DropboxBackupMetadata.Entry) -> Bool {
        guard let line = try? JSONEncoder().encode(JournalLine(shard: shard, path: path, entry: entry))
        else { return false }
        var data = line
        data.append(0x0A)   // 改行
        do {
            if FileManager.default.fileExists(atPath: journalURL.path) {
                let handle = try FileHandle(forWritingTo: journalURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: journalURL, options: .atomic)
            }
            return true
        } catch {
            BackupLogger.error("PendingMetadataStore: journal append failed — \(error)")
            return false
        }
    }

    /// 本体＋ジャーナルを合わせて読む（ジャーナルが後勝ち＝より新しい）。
    ///
    /// ⚠️ 壊れた行は**捨てずに読み飛ばす**（1 行の破損で残り全部を失わない）。
    func load() -> Payload {
        var payload: Payload = [:]
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            payload = decoded
        }
        guard let journal = try? Data(contentsOf: journalURL),
              let text = String(data: journal, encoding: .utf8) else { return payload }
        var broken = 0
        for raw in text.split(separator: "\n") {
            guard let line = try? JSONDecoder().decode(JournalLine.self, from: Data(raw.utf8)) else {
                broken += 1
                continue
            }
            payload[line.shard, default: [:]][line.path] = line.entry
        }
        if broken > 0 { BackupLogger.info("PendingMetadataStore: skipped \(broken) broken journal line(s)") }
        return payload
    }

    /// ジャーナルを消す（**送信が確認できた後だけ**呼ぶ）。
    /// 残った分は `save(_:)` が本体へ書き直しているので、ここで消しても失われない。
    func clearJournal() {
        try? FileManager.default.removeItem(at: journalURL)
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
