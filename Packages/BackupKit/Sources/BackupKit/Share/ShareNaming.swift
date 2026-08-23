import Foundation

/// 共有セットのフォルダ名サニタイズ（純ロジック・テスト対象）。
/// Dropbox のパス制約（`/ \ : ? * " < > |` 不可・前後空白/ドット不可）に合わせ、
/// ユーザー入力のセット名を安全なフォルダ名へ変換する。
public enum ShareNaming {

    /// Dropbox で使えない・トラブルの元になる文字。
    private static let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|")

    /// 種類ごとのフォルダ名接頭辞。Dropbox 上で**何のアルバムか一目で分かる**ようにし、
    /// 併せて「AI アルバムとピープルグループに同じ名前」でもフォルダが衝突しないようにする
    /// （同じ種類の中では同名を作れないので、連番はもう出ない・実フィードバック）。
    public static func prefix(for kind: ShareSourceKey.Kind) -> String {
        switch kind {
        case .album:  return "Album-"
        case .person: return "Person-"
        case .group:  return "People-"
        }
    }

    /// 種類つきのフォルダ名（例: `People-木村家` / `Album-沖縄旅行`）。
    /// 作成元が分からない場合（手動作成・旧セット）は接頭辞なし。
    public static func folderName(_ name: String, kind: ShareSourceKey.Kind?,
                                  existing: [String] = []) -> String {
        let base = sanitize(name)
        let prefixed = kind.map { prefix(for: $0) + base } ?? base
        // 接頭辞込みで衝突する場合だけ連番（通常は種類＋同名禁止で発生しない）。
        return sanitize(prefixed, existing: existing)
    }

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
