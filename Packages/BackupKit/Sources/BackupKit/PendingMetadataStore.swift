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

    /// 追記（`appendEntry`）と取り出し（`takeAll`）を直列化する錠。
    ///
    /// ⚠️ なぜ要るか（ADR-200）: 旧実装は「読む → 送る → ジャーナルをファイルごと消す」だった。
    /// 読んでから消すまでの間にも**背景アップロードの完了通知は届き続け**、1 件ごとに
    /// 1 行が追記される。その行はスナップショットに無いまま、ファイルごと消えていた——
    /// 写真の実体は上がって完了記録が付くので、その人物名・アルバム・位置情報は
    /// **二度と作られない**。錠で直列化すれば、取り出しの後の追記は必ず**新しいファイル**へ行く。
    ///
    /// 1 本のグローバルな錠で足りる（1 回の書き込みは数百バイトで、競合しても待ちは一瞬）。
    private static let journalLock = NSLock()

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
        Self.journalLock.lock()
        defer { Self.journalLock.unlock() }
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
        Self.journalLock.lock()
        defer { Self.journalLock.unlock() }
        return loadUnlocked()
    }

    /// 錠を取らない版（錠の中から呼ぶ）。
    private func loadUnlocked() -> Payload {
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

    /// **送るぶんを取り出す**（本体＋ジャーナルを 1 つにまとめ、ジャーナルを空にする）。
    ///
    /// これがキューの**唯一の消費口**。手順は錠の下で:
    ///   1. 本体とジャーナルを読んで 1 つにする
    ///   2. まとめたものを本体へ書く（原子的）
    ///   3. **本体へ書けたときだけ**ジャーナルを消す
    /// 書けなければジャーナルを残す＝次回もう一度読める（同じ内容を 2 度送るのは無害＝冪等）。
    ///
    /// ⚠️ 消費をここ 1 か所にしたので、**同じ行を 2 度送ることはもう無い**。旧実装は
    /// 実行の前半（背景経路の先出し）と後半（`writeMetadata`）の両方が `load()` していて、
    /// 前半はジャーナルを消さないため、同じ行が 1 回の実行で 2 回送られていた。しかも
    /// 「送る写真が 0 枚」の回は後半に届かないので、**ジャーナルが一度も空にならず**
    /// 窓のたびに履歴ぜんぶを送り直していた。
    func takeAll() -> Payload {
        Self.journalLock.lock()
        defer { Self.journalLock.unlock() }
        let payload = loadUnlocked()
        guard !payload.isEmpty else { return [:] }
        guard save(payload) else {
            BackupLogger.error("PendingMetadataStore: could not fold the journal — keeping it")
            return payload   // ジャーナルは残す（次回もう一度読める）
        }
        try? FileManager.default.removeItem(at: journalURL)
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
