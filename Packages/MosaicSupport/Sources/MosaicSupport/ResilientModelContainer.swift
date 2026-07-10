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
public func makeResilientModelContainer(
    name: String,
    schema: Schema,
    openFailedMessage: String,
    memoryFallbackMessage: String,
    log: (String) -> Void
) -> ModelContainer {
    let config = ModelConfiguration(name, schema: schema)
    if let container = try? ModelContainer(for: schema, configurations: [config]) { return container }
    log(openFailedMessage)
    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: config.url.path + suffix))
    }
    if let container = try? ModelContainer(for: schema, configurations: [config]) { return container }
    log(memoryFallbackMessage)
    let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return (try? ModelContainer(for: schema, configurations: [memory])) ?? (try! ModelContainer(for: schema))
}
