import Foundation

/// 写真の出所を抽象化した識別子。ローカル（PHAsset.localIdentifier）/ クラウド（Dropbox path）を統一して扱う。
/// 文字列エンコードは既存 `MergedPhotoItem` の規約に合わせて "L-…" / "C-…"。
public enum PhotoRef: Sendable, Hashable, Codable {
    case local(String)   // localIdentifier
    case cloud(String)   // Dropbox path

    public var encoded: String {
        switch self {
        case .local(let id): return "L-\(id)"
        case .cloud(let path): return "C-\(path)"
        }
    }

    public static func decode(_ s: String) -> PhotoRef? {
        if s.hasPrefix("L-") { return .local(String(s.dropFirst(2))) }
        if s.hasPrefix("C-") { return .cloud(String(s.dropFirst(2))) }
        return nil
    }

    public var isLocal: Bool { if case .local = self { return true }; return false }
    public var localIdentifier: String? { if case .local(let id) = self { return id }; return nil }
    public var cloudPath: String? { if case .cloud(let path) = self { return path }; return nil }
}
