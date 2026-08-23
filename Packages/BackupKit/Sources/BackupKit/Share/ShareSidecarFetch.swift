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

    /// 家族フォルダ群からサイドカーを列挙し、rev が前回取り込みから変わったものだけ返す。
    /// 家族フォルダ直下のサブフォルダ（＝共有セット）に加え、フォルダ自身がセットである
    /// 構成（セットフォルダを直接共有された場合）も見る。
    public func fetchUpdated(roots: [String], token: String) async -> [Fetched] {
        let copier = DropboxShareCopier(httpClient: httpClient)
        let knownRevs = Self.storedRevs()
        var out: [Fetched] = []

        for root in roots {
            var candidates = [root]
            if let listing = await copier.listFolder(path: root, token: token) {
                candidates += listing.filter(\.isFolder)
                    .map(\.pathLower)
                    .filter { !$0.hasSuffix("/" + ShareSidecar.subfolderName) }
            }
            for folder in candidates {
                let sidecarFolder = "\(folder)/\(ShareSidecar.subfolderName)"
                guard let files = await copier.listFolder(path: sidecarFolder, token: token),
                      let sidecar = files.first(where: { !$0.isFolder && $0.name == ShareSidecar.fileName })
                else { continue }
                let rev = sidecar.rev ?? ""
                if !rev.isEmpty, knownRevs[sidecar.pathLower] == rev { continue }   // 変化なし
                guard let data = await copier.downloadFile(path: sidecar.pathLower, token: token),
                      let file = ShareSidecar.decodeValidated(data) else {
                    BackupLogger.error("ShareSidecarFetch: invalid sidecar — \(sidecar.pathLower)")
                    continue
                }
                out.append(Fetched(sidecarPathLower: sidecar.pathLower, rev: rev,
                                   file: file, setFolderPathLower: folder.lowercased()))
            }
        }
        return out
    }

    /// 取り込み完了を記録する（同じ rev の再取り込みを省く）。
    public static func markImported(_ fetched: Fetched) {
        guard !fetched.rev.isEmpty else { return }
        var revs = storedRevs()
        revs[fetched.sidecarPathLower] = fetched.rev
        // 肥大防止（家族フォルダの整理でパスが変わった古い記録を無限に抱えない）。
        if revs.count > 500 {
            revs = Dictionary(uniqueKeysWithValues: Array(revs.suffix(300)))
        }
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
