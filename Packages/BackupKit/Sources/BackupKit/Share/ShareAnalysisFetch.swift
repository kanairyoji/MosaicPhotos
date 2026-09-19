import DropboxCore
import Foundation

/// 受信側: 家族の共有フォルダから解析データを見つけて取得する（ADR-112）。
/// rev（Dropbox のファイル版）を記録し、**変わったものだけ**ダウンロード・検証して返す。
/// ストアへの取り込み（TagStore / 埋め込み / 顔）はアプリ側（Composition Root）が行う。
public struct ShareAnalysisFetch {
    private let httpClient: HTTPClient

    public init(httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    /// 取得済み解析データ 1 件。
    public struct Fetched: Sendable {
        /// 解析データファイルのパス（rev 記録キー）。
        public let analysisPathLower: String
        public let rev: String
        /// 検証済みの中身。
        public let file: ShareAnalysisData.File
        /// この解析データが属するセットフォルダ（表示・ログ用）。
        public let setFolderPathLower: String
    }

    /// 家族フォルダ群から解析データ（シャード・旧形式）を列挙し、rev が前回取り込みから
    /// 変わったものだけ返す（ADR-183）。
    ///
    /// 一覧は家族フォルダごとに**再帰で 1 回**（以前はセットごとに `.mosaic-share` を
    /// list_folder していた＝N+1 回）。フォルダ自身がセットである構成（セットフォルダを
    /// 直接共有された場合）も、再帰一覧なら区別なく拾える。
    /// シャードなので、写真が増減したセットでも**変わったシャードだけ**ダウンロードする。
    /// **受信側が解析データから読み取れる項目の版**（ADR-199）。
    ///
    /// ⚠️ 「取り込み済み」の判定は rev（Dropbox のファイル版）だけなので、**受信側が賢くなっても
    /// 再取得は起きない**。解析データに新しい項目が増えたとき、旧ビルドの受信側が先に取り込んで
    /// rev を記録してしまうと、更新後もその項目は永久に届かない。
    ///
    /// 実際に踏みかけた形: 送信側が先に更新して撮影日つきのシャードを上げる → 受信側は旧ビルドの
    /// まま取り込み、`d` を無視して rev を記録 → 受信側が更新 → `fetchUpdated` は毎回 `[]` を返し、
    /// 共有アルバムはアップロード順のまま。利用者に取り戻す手段が無い。
    ///
    /// ここを上げると、次の実行で記録済み rev を 1 回だけ捨てて全部を取り直す。
    /// **解析データから新しく読む項目を足したら必ず上げる。**
    public static let receiverCapabilityVersion = 2

    private static let capabilityVersionKey = "share.receiverCapabilityVersion"

    /// 1 回の実行でダウンロードする解析データの上限（ADR-199 のレビュー指摘）。
    ///
    /// ⚠️ **一覧は全部見るが、取ってくるのは有界**。`fetchUpdated` は結果を丸ごと配列で返し、
    /// 呼び出し側（`SharedAnalysisImporter`）はそれを base64 のまま保持したうえで復号した
    /// `Data` も同時に持つ。シャードは 1 セットあたり最大 256 個あるので、
    /// 受信能力の版を上げて記録を捨てた回に**全部を 1 度に**取ると、
    /// 1 セットで 100MB 規模を同時に抱える——`PhotoEmbedding` を inline に持っていた頃の
    /// 起動クラッシュと同じ形（ADR-119/122）。しかも jetsam されると版だけ上がって
    /// 記録は空なので、毎回同じ山を作り直す無限ループになる。
    ///
    /// 取らなかったシャードは rev が古いままなので**次の実行で続きから**取れる。
    /// 総量は変わらず、「どれも少しずつ進む」状態になる（ADR-85 と同じ考え方）。
    static let maxFilesPerRun = 48

    /// 前回どこまで取ったか（次はその続きから）。
    ///
    /// ⚠️ **打ち切りだけでは進まない**（レビュー指摘）。候補から外れるのは
    /// 「取り込み済み」として rev を記録できたときだけで、その条件は何度も続けて
    /// 満たされないことがある（受信側の同期が途中だとシャードはほぼ全部が未突合）。
    /// 毎回先頭 48 個を取り直すと、**49 個目以降は一度もダウンロードされない**
    /// ——打ち切りを入れる前は全部取れていたので、これは打ち切りが作った飢餓。
    /// 続きから始めて一巡させれば、記録できない回が続いても全部が順番に回る。
    private static let cursorKey = "share.analysisFetchCursor"

    static func storedCursor() -> String? {
        UserDefaults.standard.string(forKey: cursorKey)
    }

    static func saveCursor(_ path: String?) {
        if let path { UserDefaults.standard.set(path, forKey: cursorKey) }
        else { UserDefaults.standard.removeObject(forKey: cursorKey) }
    }

    /// 候補を「前回の続き」から並べ替える（純ロジック・テスト対象）。
    /// `cursor` より大きい最初の要素から始めて、末尾まで行ったら先頭へ回り込む。
    static func rotated(_ candidates: [String], after cursor: String?) -> [String] {
        guard let cursor, !candidates.isEmpty else { return candidates }
        guard let start = candidates.firstIndex(where: { $0 > cursor }) else { return candidates }
        return Array(candidates[start...] + candidates[..<start])
    }

    /// 受信側の読み取り能力が上がっていたら、記録済み rev を 1 回だけ捨てる。
    static func invalidateRevsIfCapabilityGrew() {
        let defaults = UserDefaults.standard
        let stored = defaults.integer(forKey: capabilityVersionKey)   // 未設定は 0
        guard stored < receiverCapabilityVersion else { return }
        defaults.removeObject(forKey: ShareSettingsKeys.importedAnalysisRevs)
        defaults.set(receiverCapabilityVersion, forKey: capabilityVersionKey)
        BackupLogger.info("ShareAnalysisFetch: receiver capability \(stored) → "
            + "\(receiverCapabilityVersion) — re-fetching all analysis data once")
    }

    public func fetchUpdated(roots: [String], token: String) async -> [Fetched] {
        Self.invalidateRevsIfCapabilityGrew()
        let copier = DropboxShareCopier(httpClient: httpClient)
        let knownRevs = Self.storedRevs()
        var out: [Fetched] = []
        var seenPaths = Set<String>()
        var allListed = true

        // 1 巡目: 一覧を全部見て、候補（rev が変わったもの）を集める。
        // ⚠️ 一覧には**必ず**入れる（打ち切っても記録の掃除が狂わないように）。
        var candidates: [(path: String, rev: String, setFolder: String)] = []
        for root in roots {
            guard let listing = await copier.listFolder(path: root, token: token, recursive: true) else {
                allListed = false   // 一覧が取れない回は記録を捨てない（全部の再取得を誘発する）
                continue
            }
            let marker = "/" + ShareAnalysisData.subfolderName + "/"
            for file in listing where !file.isFolder && ShareAnalysisData.isAnalysisFileName(file.name) {
                guard let range = file.pathLower.range(of: marker, options: .backwards) else { continue }
                seenPaths.insert(file.pathLower)
                let rev = file.rev ?? ""
                if !rev.isEmpty, knownRevs[file.pathLower] == rev { continue }   // 変化なし
                candidates.append((file.pathLower, rev,
                                   String(file.pathLower[..<range.lowerBound])))
            }
        }

        // 2 巡目: 前回の続きから上限まで取る（一巡させて飢餓を作らない）。
        let order = Dictionary(candidates.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let rotatedPaths = Self.rotated(candidates.map(\.path).sorted(), after: Self.storedCursor())
        var lastTaken: String?
        for path in rotatedPaths.prefix(Self.maxFilesPerRun) {
            guard let candidate = order[path] else { continue }
            lastTaken = path
            guard let data = await copier.downloadFile(path: path, token: token),
                  let decoded = ShareAnalysisData.decodeValidated(data) else {
                BackupLogger.error("ShareAnalysisFetch: invalid analysis data — \(path)")
                continue
            }
            out.append(Fetched(analysisPathLower: path, rev: candidate.rev,
                               file: decoded, setFolderPathLower: candidate.setFolder))
        }
        // 壊れていて取り込めないシャードでも印は進める（そこで止まらない）。
        if let lastTaken { Self.saveCursor(lastTaken) }
        // 一覧に無くなったパスの rev 記録は捨てる（肥大防止。以前の「500 件超で末尾 300 件」は
        // シャード化で件数が増えると取り込み済みの記録まで捨てて再取得を誘発する）。
        if allListed { Self.pruneStoredRevs(keeping: seenPaths) }
        return out
    }

    /// 取り込み完了を記録する（同じ rev の再取り込みを省く）。
    public static func markImported(_ fetched: Fetched) {
        guard !fetched.rev.isEmpty else { return }
        var revs = storedRevs()
        revs[fetched.analysisPathLower] = fetched.rev
        save(revs)
    }

    /// 一覧に無くなったパスの記録を捨てる（家族フォルダの整理・シャードの消滅）。
    static func pruneStoredRevs(keeping paths: Set<String>) {
        let revs = storedRevs()
        let kept = revs.filter { paths.contains($0.key) }
        if kept.count != revs.count { save(kept) }
    }

    private static func save(_ revs: [String: String]) {
        if let data = try? JSONEncoder().encode(revs) {
            UserDefaults.standard.set(data, forKey: ShareSettingsKeys.importedAnalysisRevs)
        }
    }

    static func storedRevs() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: ShareSettingsKeys.importedAnalysisRevs),
              let revs = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return revs
    }
}
