import Foundation

/// Caches ディレクトリ配下の JSON ファイルに `Codable` 値を読み書きする小さなユーティリティ。
/// スキャナや解決器のキャッシュ永続化（load/save）の重複を一箇所に集約する。
public struct JSONFileStore<Value: Codable>: Sendable {
    private let url: URL

    /// - Parameters:
    ///   - filename: 基準ディレクトリからの相対パス（例 "Places/placeIndex.json"）。
    ///   - directory: 基準ディレクトリ。既定は Caches（OS により破棄され得る）。永続させたい
    ///     ものは `.applicationSupportDirectory` を指定する。
    public init(filename: String, in directory: FileManager.SearchPathDirectory = .cachesDirectory) {
        let base = FileManager.default.urls(for: directory, in: .userDomainMask)[0]
        url = base.appendingPathComponent(filename)
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    /// ⚠️ **エンコードと書き込みは呼び出し元のスレッドで走る。** 数万件の辞書を MainActor から
    /// 保存すると、そのまま前面の停止になる（CLAUDE.md 性能原則 4「巨大コレクションを
    /// MainActor に通さない」）。大きい値は `saveInBackground(_:)` を使うこと。
    public func save(_ value: Value) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

extension JSONFileStore where Value: Sendable {
    /// **エンコードと書き込みを呼び出し元のスレッドから外して**保存する。
    ///
    /// キャッシュの保存は「すぐ書けたか」より「呼び出し元を止めないこと」が大事で、
    /// 失われても次回作り直せる。戻り値の `Task` を待てば書き終わりを確かめられる
    /// （テスト・確実に残したい場面のみ。通常は待たない）。
    ///
    /// ⚠️ 同じファイルへ同時に書くと**最後の書き手が勝つ**（`.atomic` なのでファイルが
    /// 壊れることはない）。作り直せるキャッシュに使うこと。
    @discardableResult
    public func saveInBackground(_ value: Value) -> Task<Void, Never> {
        let store = self
        return Task.detached(priority: .utility) { store.save(value) }
    }
}
