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

    /// 共有に**人物名を含めるか**（既定 ON・ADR-167）。
    /// OFF にすると顔（グルーピングの材料）だけを送り、名前は送らない。
    /// ⚠️ 名前は個人情報なので、送らない選択ができること自体に意味がある。
    public static let shareNamesEnabled = "shareNamesEnabled"
    public static func isShareNamesEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: shareNamesEnabled) == nil
            ? true : defaults.bool(forKey: shareNamesEnabled)
    }

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

    /// 旧: 自分が共有を書き出すルートフォルダ（既定 `/MosaicShare`）。
    ///
    /// ⚠️ **廃止**（ADR-175）。共有はバックアップと同じルートの端末フォルダ配下 `Share/` に置く
    /// ので、共有だけの別ルートは持たない。キーは**旧設定の検出**（移行案内）のためだけに残す。
    public static let legacyShareRootFolder = "shareRootFolder"
    public static let legacyDefaultShareRootFolder = "/MosaicShare"

    /// 家族から共有されたフォルダ（受信側）。JSON エンコードした [String]。
    /// 同期ルートへの追加と解析サイドカーの取り込み対象を兼ねる。
    public static let familyFolders = "shareFamilyFolders"

    /// 取り込み済みサイドカーの rev 記録（[path: rev] の JSON）。同一 rev の再取り込みを省く。
    public static let importedSidecarRevs = "shareImportedSidecarRevs"

    /// 現在の共有ルート（ADR-175）: **バックアップと同じルート**の端末フォルダ配下 `Share/`。
    ///
    /// ⚠️ 旧設定（`/MosaicShare`）はもう見ない。`SharePlanning.setFolderPath` は
    /// `deviceFolder` を足す引数を持つが、ここで返す値は**端末フォルダ込み**なので
    /// 呼び出し側は `deviceFolder: nil` で使う（二重に足さない）。
    public static func currentShareRoot(_ defaults: UserDefaults = .standard) -> String {
        let backupRoot = defaults.string(forKey: BackupSettingsKeys.dropboxFolder)
            ?? BackupSettingsKeys.defaultDropboxFolder
        return BackupLayout.shareRoot(root: backupRoot,
                                      deviceFolder: BackupDeviceIdentity.currentFolderName())
    }

    /// 旧配置の共有ルート（`/MosaicShare`）が設定に残っているか。
    /// 移行しない方針（ADR-175）なので、**旧フォルダが残っていることを案内する**ためだけに使う。
    public static func legacyShareRootIfAny(_ defaults: UserDefaults = .standard) -> String? {
        guard let raw = defaults.string(forKey: legacyShareRootFolder) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
    /// ⚠️ **フォルダ墓標にだけ**使う。単枚の墓標は時間で消さない（ADR-172）——
    /// 猶予後にコピージョブが完走すると、外したはずの写真が残り続けるため。
    public static let deletedFolderGraceSeconds: TimeInterval = 15 * 60

    /// 単枚の墓標の上限（古い順に捨てる）。不在を確認できるまで残す方針なので時間では消さないが、
    /// 設定の肥大は避ける。ここに達するのは異常事態（確認が延々できていない）。
    public static let maxFileTombstones = 5000

    /// **単枚**の墓標（メンバーから外した写真の予定コピー先）。フォルダ墓標と同じ理由で要る——
    /// 反映を止めても、発行済みの copy_batch はサーバー側で完走するため、記録を消した後に
    /// ファイルだけが現れる（レビュー指摘）。
    public static let deletedFiles = "shareDeletedFiles"

    public static func deletedFileTombstones(account: String?,
                                             _ defaults: UserDefaults = .standard) -> [String: Date] {
        tombstones(key: deletedFiles, account: account, defaults)
    }

    public static func setDeletedFileTombstones(_ value: [String: Date], account: String?,
                                                _ defaults: UserDefaults = .standard) {
        setTombstones(value, key: deletedFiles, account: account, defaults)
    }

    private static func tombstones(key: String, account: String?,
                                   _ defaults: UserDefaults) -> [String: Date] {
        guard let raw = defaults.dictionary(forKey: key) as? [String: Double] else { return [:] }
        let prefix = "\(account ?? "-")|"
        var out: [String: Date] = [:]
        for (k, time) in raw where k.hasPrefix(prefix) {
            out[String(k.dropFirst(prefix.count))] = Date(timeIntervalSince1970: time)
        }
        return out
    }

    private static func setTombstones(_ value: [String: Date], key: String, account: String?,
                                      _ defaults: UserDefaults) {
        var raw = (defaults.dictionary(forKey: key) as? [String: Double]) ?? [:]
        let prefix = "\(account ?? "-")|"
        for k in raw.keys where k.hasPrefix(prefix) { raw.removeValue(forKey: k) }
        for (path, date) in value { raw["\(prefix)\(path)"] = date.timeIntervalSince1970 }
        defaults.set(raw, forKey: key)
    }

    /// 墓標のキー。**アカウントを含める**こと。
    ///
    /// ⚠️ パスだけを鍵にすると、削除から猶予時間（15 分）の内に Dropbox アカウントを切り替えたとき、
    /// **新しいアカウントの同じパスのフォルダを消しに行く**（レビュー指摘）。共有ルートは既定値が
    /// 同じなので、別アカウントでも同名パスは普通に存在する。
    static func tombstoneKey(account: String?, path: String) -> String {
        "\(account ?? "-")|\(path)"
    }

    /// 指定アカウントぶんの墓標（キーはパス）。account が nil のときは「持ち主不明」の分だけ返す。
    public static func deletedFolderTombstones(account: String?,
                                               _ defaults: UserDefaults = .standard) -> [String: Date] {
        tombstones(key: deletedFolders, account: account, defaults)
    }

    /// 指定アカウントぶんの墓標を置き換える（他アカウントの分は触らない）。
    public static func setDeletedFolderTombstones(_ value: [String: Date], account: String?,
                                                  _ defaults: UserDefaults = .standard) {
        setTombstones(value, key: deletedFolders, account: account, defaults)
    }
}
