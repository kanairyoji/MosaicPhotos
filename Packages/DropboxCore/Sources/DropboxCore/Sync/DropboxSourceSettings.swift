import Foundation

/// Dropbox の読み込み対象フォルダ（ソーススコープ）の設定と正規化（ADR-44）。
///
/// 既定は "/"（アカウント全体）。特定フォルダを指定すると、同期・サムネイル・AI 索引の
/// 対象がそのフォルダ以下に限定される。**バックアップフォルダは常に同期対象に含める**
/// （オフロードのクラウド代替・バックアップ済み写真の表示を壊さないため）——
/// 実際のルート一覧はアプリ（Composition Root）が `DropboxPhotoStore.syncRootsProvider` で
/// 「選択フォルダ＋バックアップフォルダ」を渡し、`normalizedRoots` が重複・包含を畳む。
public enum DropboxSourceSettings {

    /// UserDefaults キー（読み込み対象フォルダ。"/" または "" = 全体）。
    public static let sourceFolderKey = "dropboxSourceFolder"

    /// 現在の設定値（正規化済み・"" = 全体）。
    public static func currentSourceFolder() -> String {
        normalized(UserDefaults.standard.string(forKey: sourceFolderKey) ?? "/")
    }

    /// パスの正規化: 前後空白除去・先頭スラッシュ付与・末尾スラッシュ除去。
    /// "/" と "" は「全体」を意味する "" に揃える（Dropbox API の list_folder は root を "" で表す）。
    public static func normalized(_ path: String) -> String {
        var s = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "/" { return "" }
        if !s.hasPrefix("/") { s = "/" + s }
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 同期ルート一覧の正規化: 各要素を正規化 → 重複除去 → **他のルートの配下にあるものを除去**
    /// （"" が含まれれば全体 1 本に畳まれる。"/A" と "/A/B" は "/A" だけ残る）。
    /// 大文字小文字は無視して包含判定する（Dropbox パスは case-insensitive）。
    public static func normalizedRoots(_ paths: [String]) -> [String] {
        let cleaned = paths.map { normalized($0) }
        if cleaned.contains("") { return [""] }
        var unique: [String] = []
        for p in cleaned where !unique.contains(where: { $0.lowercased() == p.lowercased() }) {
            unique.append(p)
        }
        // 祖先が存在する要素を落とす。
        return unique.filter { candidate in
            !unique.contains { other in
                other.lowercased() != candidate.lowercased()
                    && candidate.lowercased().hasPrefix(other.lowercased() + "/")
            }
        }
    }
}
