import DropboxCore
import Foundation

/// 受信側: 家族の共有フォルダから解析サイドカーを見つけて取得する（ADR-112）。
/// rev（Dropbox のファイル版）を記録し、**変わったものだけ**ダウンロード・検証して返す。
/// ストアへの取り込み（TagStore / 埋め込み / 顔）はアプリ側（Composition Root）が行う。
public struct ShareSidecarFetch {
    private let httpClient: HTTPClient

    public init(httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    /// 取得済みサイドカー 1 件。
    public struct Fetched: Sendable {
        /// サイドカーファイルのパス（rev 記録キー）。
        public let sidecarPathLower: String
        public let rev: String
        /// 検証済みの中身。
        public let file: ShareSidecar.File
        /// このサイドカーが属するセットフォルダ（表示・ログ用）。
        public let setFolderPathLower: String
    }

    /// 家族フォルダ群からサイドカー（シャード・旧形式）を列挙し、rev が前回取り込みから
    /// 変わったものだけ返す（ADR-183）。
    ///
    /// 一覧は家族フォルダごとに**再帰で 1 回**（以前はセットごとに `.mosaic-share` を
    /// list_folder していた＝N+1 回）。フォルダ自身がセットである構成（セットフォルダを
    /// 直接共有された場合）も、再帰一覧なら区別なく拾える。
    /// シャードなので、写真が増減したセットでも**変わったシャードだけ**ダウンロードする。
    public func fetchUpdated(roots: [String], token: String) async -> [Fetched] {
        let copier = DropboxShareCopier(httpClient: httpClient)
        let knownRevs = Self.storedRevs()
        var out: [Fetched] = []
        var seenPaths = Set<String>()
        var allListed = true

        for root in roots {
            guard let listing = await copier.listFolder(path: root, token: token, recursive: true) else {
                allListed = false   // 一覧が取れない回は記録を捨てない（全部の再取得を誘発する）
                continue
            }
            let marker = "/" + ShareSidecar.subfolderName + "/"
            for file in listing where !file.isFolder && ShareSidecar.isSidecarFileName(file.name) {
                guard let range = file.pathLower.range(of: marker, options: .backwards) else { continue }
                seenPaths.insert(file.pathLower)
                let rev = file.rev ?? ""
                if !rev.isEmpty, knownRevs[file.pathLower] == rev { continue }   // 変化なし
                guard let data = await copier.downloadFile(path: file.pathLower, token: token),
                      let decoded = ShareSidecar.decodeValidated(data) else {
                    BackupLogger.error("ShareSidecarFetch: invalid sidecar — \(file.pathLower)")
                    continue
                }
                let setFolder = String(file.pathLower[..<range.lowerBound])
                out.append(Fetched(sidecarPathLower: file.pathLower, rev: rev,
                                   file: decoded, setFolderPathLower: setFolder))
            }
        }
        // 一覧に無くなったパスの rev 記録は捨てる（肥大防止。以前の「500 件超で末尾 300 件」は
        // シャード化で件数が増えると取り込み済みの記録まで捨てて再取得を誘発する）。
        if allListed { Self.pruneStoredRevs(keeping: seenPaths) }
        return out
    }

    /// 取り込み完了を記録する（同じ rev の再取り込みを省く）。
    public static func markImported(_ fetched: Fetched) {
        guard !fetched.rev.isEmpty else { return }
        var revs = storedRevs()
        revs[fetched.sidecarPathLower] = fetched.rev
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
            UserDefaults.standard.set(data, forKey: ShareSettingsKeys.importedSidecarRevs)
        }
    }

    static func storedRevs() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: ShareSettingsKeys.importedSidecarRevs),
              let revs = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return revs
    }
}
