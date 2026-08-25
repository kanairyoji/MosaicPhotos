import Foundation

/// 撮影月シャード（`<deviceRoot>/.mosaic/meta/<YYYY-MM>.json`）への
/// 「download → merge → upload」を**シャード単位でプロセス内直列化**するロック。
///
/// ## なぜ必要か（レビュー指摘）
/// バックアップ（`BackupRunner.writeMetadata` → `MetadataShardWriter.applyEntries`）と
/// オフロード（`OffloadService.uploadOffloadMarkers` → `updateEntries`）は、同じシャードに対して
/// read-modify-write を行う。どちらも `@MainActor` だが `await` をまたいで割り込むため実際に
/// インターリーブし、両者が同じ旧シャードを読むと**後着の overwrite が先着の変更を消す**。
/// 消えるのがオフロードマーカーだと、オフロード側は `markOffloadMarkersUploaded` 済みなので
/// 再送もされず、再インストール後に台帳を再構築できなくなる。
///
/// download の直前に取り upload の応答後に解放するので、片方の read-modify-write が完了して
/// からもう片方が読み直す＝両方の変更が最終内容に残る。
actor MetadataShardLock {

    static let shared = MetadataShardLock()

    /// 現在ロック中のキー（シャードのフルパス・小文字）。
    private var locked: Set<String> = []
    /// キーごとの待ち行列（FIFO）。
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    private func acquire(_ key: String) async {
        guard locked.contains(key) else {
            locked.insert(key)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[key, default: []].append(continuation)
        }
    }

    private func release(_ key: String) {
        guard var queue = waiters[key], !queue.isEmpty else {
            locked.remove(key)
            return
        }
        // ロックは保持したまま次の待ち手へ渡す（hand-off・割り込みを許さない）。
        let next = queue.removeFirst()
        if queue.isEmpty {
            waiters.removeValue(forKey: key)
        } else {
            waiters[key] = queue
        }
        next.resume()
    }

    /// `key` のロックを取って `body` を実行し、完了後に解放する。
    static func withLock<T>(_ key: String, _ body: () async -> T) async -> T {
        await shared.acquire(key)
        let value = await body()
        await shared.release(key)
        return value
    }
}
