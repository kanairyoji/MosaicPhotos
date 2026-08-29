import Foundation
import SwiftData

/// 名前付き永続 ModelContainer を「自己修復」で構築する共通ロジック。
/// SwiftData の `ModelContainer` 初期化はストア破損・スキーマ不整合のとき起動時に trap して
/// 実機で原因不明のクラッシュになりやすい。そこで「失敗 → store ファイル（.store / -wal / -shm）を
/// 削除して再構築 → なお失敗ならインメモリ」とフォールバックし、trap せず必ず ModelContainer を
/// 返して起動を止めない（データは失うが回復＝再構築される）。
/// `AutoAlbumStore` / `TagStore` / `FaceStore` / `DropboxCacheStore` / `BackupEngine` が共用する。
///
/// - Parameters:
///   - name: `ModelConfiguration` の名前（"<name>.store" になる。名前なしは "default.store" で
///     他コンテナと衝突するため必ず明示する）。
///   - schema: コンテナのスキーマ。
///   - openFailedMessage: 初回オープン失敗（store 削除→再構築へ進む）時のログ文言。
///   - memoryFallbackMessage: 再構築も失敗（インメモリへ落とす）時のログ文言。
///   - log: 失敗を記録するログチャネル（呼び出し元の `LogChannel.error` 等を注入する）。
/// 便利版: name からメッセージを自動生成する `makeResilientModelContainer`。
/// 各パッケージの @ModelActor ストア（AutoAlbum/Tags/Faces/Usage）が別コンテナ生成に共用する。
public func resilientModelContainer(name: String, schema: Schema,
                                    policy: StoreRecoveryPolicy = .rebuildable,
                                    log: @escaping (String) -> Void = { _ in }) -> ModelContainer {
    makeResilientModelContainer(
        name: name, schema: schema, policy: policy,
        openFailedMessage: "ModelContainer '\(name)' open failed; deleting store and rebuilding (data reset).",
        memoryFallbackMessage: "ModelContainer '\(name)' still failing; using in-memory store.",
        log: log)
}

public func makeResilientModelContainer(
    name: String,
    schema: Schema,
    policy: StoreRecoveryPolicy = .rebuildable,
    openFailedMessage: String,
    memoryFallbackMessage: String,
    log: (String) -> Void
) -> ModelContainer {
    let config = ModelConfiguration(name, schema: schema)
    do {
        return try ModelContainer(for: schema, configurations: [config])
    } catch {
        log(openFailedMessage + " — \(error)")
        // ⚠️ **失敗の理由を見てから**手を決める。理由を見ずに削除すると、容量不足や
        // ファイル保護（端末ロック中）のような一時的な失敗でも台帳を失う（レビュー指摘）。
        switch StoreRecovery.action(for: error, policy: policy) {
        case .keepFilesUseMemory:
            log("ModelContainer '\(name)': transient failure — keeping files, using in-memory this launch.")
            Diagnostics.mark("store: '\(name)' transient open failure — files kept, in-memory")
        case .deleteAndRebuild:
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: config.url.path + suffix))
            }
            Diagnostics.mark("store: '\(name)' deleted and rebuilt (rebuildable cache)")
        case .quarantineAndRebuild:
            // 台帳は消さない。退避して残す（二重アップロード・共有の齟齬を避けるため、
            // 後から回収・調査できる状態にしておく）。
            quarantine(storeURL: config.url, name: name, log: log)
        }
        if let container = try? ModelContainer(for: schema, configurations: [config]) { return container }
        log(memoryFallbackMessage)
        // ⚠️ 名前を分ける。既定名のインメモリ構成はプロセス内で共有されるので、別々の台帳
        // （FacesV1 / TagsV1 …）が同時にフォールバックすると 1 つの箱に混ざる。
        let memory = ModelConfiguration("\(name)-memory", schema: schema, isStoredInMemoryOnly: true)
        return (try? ModelContainer(for: schema, configurations: [memory])) ?? (try! ModelContainer(for: schema))
    }
}

/// 壊れた台帳を退避する（削除しない）。3 世代を超えたら古いものから捨てる。
private func quarantine(storeURL: URL, name: String, log: (String) -> Void) {
    let fm = FileManager.default
    let exists: (URL) -> Bool = { fm.fileExists(atPath: $0.path) }
    var moved = false
    for suffix in ["", "-wal", "-shm"] {
        let source = URL(fileURLWithPath: storeURL.path + suffix)
        guard exists(source) else { continue }
        let destination = StoreRecovery.quarantineURL(for: source, existing: exists)
        do {
            try fm.moveItem(at: source, to: destination)
            moved = true
        } catch {
            // 退避できないなら**消さない**（そのまま残してインメモリで起動する）。
            log("ModelContainer '\(name)': quarantine failed — \(error)")
        }
    }
    if moved {
        log("ModelContainer '\(name)': ledger quarantined (files kept for recovery).")
        Diagnostics.mark("store: '\(name)' quarantined (ledger corrupt)")
    }
    pruneQuarantines(of: storeURL, keep: 3)
}

/// 退避ファイルの世代を絞る（無制限に溜めない）。
///
/// ⚠️ 退避名は本体だけでなく `<store>-wal.corrupt` / `<store>-shm.corrupt` も作られる。
/// 本体の名前（`<store>.corrupt`）だけを見て消すと、**WAL/SHM の退避が消えずに溜まり続ける**
/// （レビュー指摘）。`<store>` で始まり `.corrupt` を含むものを対象にし、
/// **世代（.corrupt / .corrupt2 …）単位**で古いものから消す。
func pruneQuarantines(of storeURL: URL, keep: Int) {
    let fm = FileManager.default
    let directory = storeURL.deletingLastPathComponent()
    let base = storeURL.lastPathComponent           // 例: "BackupKit.store"
    guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                    includingPropertiesForKeys: [.creationDateKey])
    else { return }

    /// ファイル名から世代の印（"corrupt" / "corrupt2" / "corrupt-ab12cd34"）を取り出す。
    func generation(of name: String) -> String? {
        guard name.hasPrefix(base) else { return nil }
        guard let range = name.range(of: ".corrupt") else { return nil }
        return String(name[range.lowerBound...].dropFirst())   // 先頭の "." を落とす
    }

    var byGeneration: [String: [URL]] = [:]
    for entry in entries {
        guard let gen = generation(of: entry.lastPathComponent) else { continue }
        byGeneration[gen, default: []].append(entry)
    }
    guard byGeneration.count > keep else { return }

    func newest(_ urls: [URL]) -> Date {
        urls.compactMap { (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) }
            .max() ?? .distantPast
    }
    let ordered = byGeneration.sorted { newest($0.value) > newest($1.value) }
    for (_, urls) in ordered.dropFirst(keep) {
        for url in urls { try? fm.removeItem(at: url) }
    }
}
