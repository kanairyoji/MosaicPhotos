import Foundation

/// 共有セットのフォルダ名サニタイズ（純ロジック・テスト対象）。
/// Dropbox のパス制約（`/ \ : ? * " < > |` 不可・前後空白/ドット不可）に合わせ、
/// ユーザー入力のセット名を安全なフォルダ名へ変換する。
public enum ShareNaming {

    /// Dropbox で使えない・トラブルの元になる文字。
    private static let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|")

    /// セット名 → フォルダ名。空になった場合は "Shared" にフォールバック。
    /// `existing`（小文字比較）と衝突したら " 2", " 3", … を付ける。
    public static func sanitize(_ name: String, existing: [String] = []) -> String {
        var cleaned = String(name.unicodeScalars.map { forbidden.contains($0) ? "_" : Character($0) })
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasSuffix(".") { cleaned.removeLast() }
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 80 { cleaned = String(cleaned.prefix(80)) }
        if cleaned.isEmpty { cleaned = "Shared" }

        let lowerExisting = Set(existing.map { $0.lowercased() })
        guard lowerExisting.contains(cleaned.lowercased()) else { return cleaned }
        for n in 2...999 {
            let candidate = "\(cleaned) \(n)"
            if !lowerExisting.contains(candidate.lowercased()) { return candidate }
        }
        return "\(cleaned) \(UUID().uuidString.prefix(8))"
    }
}
