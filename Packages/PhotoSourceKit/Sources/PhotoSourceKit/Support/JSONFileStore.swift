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

    public func save(_ value: Value) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
