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

    /// **同じ Dropbox に接続している人へ、解析結果を公開するか**（既定 ON・ADR-222）。
    ///
    /// クラウドの写真は接続しただけで相手からも見えるのに、解析（タグ・CLIP 埋め込み・顔・
    /// 人物名・撮影日）は各自の端末でやり直しになっていた。ON なら `<root>/<端末>/Analysis` へ
    /// 解析結果だけを置き、同じ Dropbox に接続した端末が取り込める。
    /// ⚠️ 人物名を載せるかは従来どおり `shareNamesEnabled` が決める（OFF なら顔だけ）。
    /// 解析結果を公開するか（ADR-222）。
    ///
    /// ⚠️ **既定は OFF**（ADR-222 追補）。公開は端末フォルダごとに分かれるのでファイルは壊れないが、
    /// 2 台で ON にすると**同じ写真の解析が台数ぶん Dropbox に積まれる**（1 台 100〜200MB）。
    /// 「気づいたら容量を倍使っていた」を既定にしたくないので、入れるのは利用者の意思に任せる。
    public static let publishAnalysisEnabled = "sharePublishAnalysisEnabled"
    /// ⚠️ **画面の `@AppStorage` にもこれを渡す**（実機ログ diagnostics-86）。
    /// 既定を OFF にしたとき、キーの読み出し側だけ直して画面側は `= true` のままだった
    /// ——**トグルは ON に見えるのに公開は「設定がオフ」で何もしない**、という食い違いになる。
    /// 既定は 1 か所にしか書かない。
    public static let publishAnalysisDefault = false
    public static func isPublishAnalysisEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: publishAnalysisEnabled) == nil
            ? publishAnalysisDefault : defaults.bool(forKey: publishAnalysisEnabled)
    }

    /// 「別の端末が公開しているが、この端末で公開する」と利用者が選んだときの、
    /// **そのとき名乗っていた端末**のフォルダ名（`AnalysisOwnership.decide` に渡す）。
    public static let acknowledgedAnalysisOwner = "shareAcknowledgedAnalysisOwner"

    /// 公開済みシャードの指紋（[シャード名: 指紋] の JSON）。変わったシャードだけ上げ直す。
    public static let publishedAnalysisDigests = "sharePublishedAnalysisDigests"
    /// 公開の続きの位置（1 回の実行で上げるシャード数に上限があるため）。
    public static let publishAnalysisCursor = "sharePublishAnalysisCursor"

    /// 家族から共有されたフォルダ（受信側）。JSON エンコードした [String]。
    /// 同期ルートへの追加と解析データの取り込み対象を兼ねる。
    public static let familyFolders = "shareFamilyFolders"

    /// 取り込み済み解析データの rev 記録（[path: rev] の JSON）。同一 rev の再取り込みを省く。
    public static let importedAnalysisRevs = "shareImportedSidecarRevs"   // 値は互換のため据え置き（rev 記録を失わない）

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

    // ⚠️ **墓標は撤去した**（ADR-209）。「消したフォルダ／消す予定だったファイル」を
    // 覚えておいて後から掃除する仕組みは、反映が差分になったことで要らなくなった——
    // 遅れて完走したコピーが何を作っても、それは「望ましくない」側に入るので次の反映が消す。
}
