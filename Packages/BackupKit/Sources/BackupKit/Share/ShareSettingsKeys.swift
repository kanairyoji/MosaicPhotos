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

    /// ⚠️ 読み出しは `defaults` を引数に取る（既定 `.standard`）。テストが**自分専用の
    /// UserDefaults スイート**を渡せるようにするため——共有の設定はプロセス全体で 1 つなので、
    /// 並列実行するテストが互いのフラグを踏んで落ちる（実際に踏んだ）。
    public static func isReceiveEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: receiveEnabled) == nil
            ? true : defaults.bool(forKey: receiveEnabled)
    }
    public static func isProvideEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: provideEnabled) == nil
            ? true : defaults.bool(forKey: provideEnabled)
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
    public static func currentShareRoot(_ defaults: UserDefaults = .standard) -> String {
        let raw = defaults.string(forKey: shareRootFolder) ?? defaultShareRootFolder
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

    // MARK: - 削除した共有フォルダの墓標（[パス: 削除時刻]）

    /// ⚠️ **クライアントがポーリングをやめても、Dropbox 側のコピージョブは走り続ける**。
    /// セットを削除した直後にジョブが完走すると、消したはずのフォルダが**復活**し、
    /// 記録は消えているので誰も掃除できない孤児になる。削除したフォルダを一定時間だけ
    /// 覚えておき、以後の反映で「まだ在るなら消し直す」ために使う。
    public static let deletedFolders = "shareDeletedFolders"

    /// 墓標を覚えておく時間。非同期ジョブの上限（約 4 分）に余裕を見た値。
    public static let deletedFolderGraceSeconds: TimeInterval = 15 * 60

    public static func deletedFolderTombstones(_ defaults: UserDefaults = .standard)
        -> [String: Date] {
        guard let raw = defaults.dictionary(forKey: deletedFolders) as? [String: Double]
        else { return [:] }
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    public static func setDeletedFolderTombstones(_ value: [String: Date],
                                                  _ defaults: UserDefaults = .standard) {
        defaults.set(value.mapValues { $0.timeIntervalSince1970 }, forKey: deletedFolders)
    }
}
