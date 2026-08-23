import Foundation

/// クラウド共有の永続設定キー。
/// 「受ける」「提供する」「バックアップ」は独立した機能として別々に設定できる（ADR-112 追記）。
public enum ShareSettingsKeys {
    /// クラウド共有を**受ける**機能の有効フラグ（既定 ON）。
    /// バックアップ・提供とは無関係に動く（必要なのは Dropbox 接続のみ）。
    public static let receiveEnabled = "shareReceiveEnabled"
    /// クラウド共有を**提供する**機能の有効フラグ（既定 ON）。
    /// OFF にすると共有メニューが消え、既存セットの反映も止まる。
    public static let provideEnabled = "shareProvideEnabled"

    public static func isReceiveEnabled() -> Bool {
        UserDefaults.standard.object(forKey: receiveEnabled) == nil
            ? true : UserDefaults.standard.bool(forKey: receiveEnabled)
    }
    public static func isProvideEnabled() -> Bool {
        UserDefaults.standard.object(forKey: provideEnabled) == nil
            ? true : UserDefaults.standard.bool(forKey: provideEnabled)
    }

    /// 自分が共有を書き出すルートフォルダ（既定 `/MosaicShare`）。
    /// ユーザーはこのフォルダを Dropbox 側で家族に共有する（閲覧のみ招待を推奨）。
    public static let shareRootFolder = "shareRootFolder"
    public static let defaultShareRootFolder = "/MosaicShare"

    /// 家族から共有されたフォルダ（受信側）。JSON エンコードした [String]。
    /// 同期ルートへの追加と解析サイドカーの取り込み対象を兼ねる。
    public static let familyFolders = "shareFamilyFolders"

    /// 取り込み済みサイドカーの rev 記録（[path: rev] の JSON）。同一 rev の再取り込みを省く。
    public static let importedSidecarRevs = "shareImportedSidecarRevs"

    /// 現在の共有ルート（正規化済み）。
    public static func currentShareRoot() -> String {
        let raw = UserDefaults.standard.string(forKey: shareRootFolder) ?? defaultShareRootFolder
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else { return defaultShareRootFolder }
        var s = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 家族フォルダ一覧（正規化済み・重複除去）。
    public static func currentFamilyFolders() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: familyFolders),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        var out: [String] = []
        for raw in list {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, s != "/" else { continue }
            if !s.hasPrefix("/") { s = "/" + s }
            while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
            if !out.contains(where: { $0.lowercased() == s.lowercased() }) { out.append(s) }
        }
        return out
    }

    public static func setFamilyFolders(_ folders: [String]) {
        let data = (try? JSONEncoder().encode(folders)) ?? Data()
        UserDefaults.standard.set(data, forKey: familyFolders)
    }
}
