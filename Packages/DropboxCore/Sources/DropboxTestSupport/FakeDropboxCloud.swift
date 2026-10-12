import Foundation
import DropboxCore

/// **複数アカウントの Dropbox**（テスト専用）。家族共有の「送る人」と「受ける人」は
/// 別々の Dropbox アカウントで、共有フォルダは**受ける人の Dropbox の中に現れる**。
///
/// ## なぜ要るか
/// `FakeDropboxServer` は 1 アカウントしか表せず、家族共有の通しは「送る端末と受ける端末を
/// 同じ Dropbox の上でつなぐ」形でしか書けなかった。本物は違う:
/// - 受ける人には、共有されたフォルダが**自分のルート直下の別の名前**で見える
///   （同名が既にあれば `Share (1)` のように付け直される）
/// - 「閲覧のみ」の共有フォルダには書き込めない（`no_write_permission`）
/// - 共有を外されると、そのフォルダは受ける人の Dropbox から**消える**
///   （一覧は `path/not_found`、そこに張った差分カーソルも `path/not_found`）
/// - 送る人がコピー・削除したものは、受ける人の差分に届く（中身は 1 つ）
///
/// ## 作り
/// 中身は 1 つの `FakeDropboxServer`（＝Dropbox のサーバー全体）に置き、アカウントごとの
/// 名前空間を `/~<id>` の下に持つ。各アカウントの `FakeDropboxAccount` は `HTTPClient` で、
/// **要求のパスを全体のパスへ、応答のパスをアカウントから見えるパスへ**書き換える。
/// ファイル表・rev・日付・差分・障害注入はすべて `FakeDropboxServer` のものがそのまま効く
/// （偽物を 2 つにしない＝`FakeDropboxServer` 冒頭の決まり）。
///
/// ## 割り切り（本物と違うところ）
/// - 共有フォルダの置き場所はルート直下だけ（本物は受ける人が後で動かせる）
/// - アカウントのルート（`""`）の一覧は 1 ページで返す（共有フォルダを混ぜるため）。
///   ルートに張る差分カーソルは**作らない**（400 を返す＝使ったテストが気づける）
/// - 閲覧のみのフォルダへの書き込みが混ざったバッチは、**バッチごと** 409 にする
///   （本物はエントリごとに失敗を返す。アプリは混ぜないので、混ぜたら落ちる方が安全）
/// - 容量は全体で 1 つ（`FakeDropboxServer.setFreeSpace`）
public actor FakeDropboxCloud {

    public enum Access: Sendable, Equatable { case viewer, editor }

    /// 中身（全アカウントぶん）。障害注入・遅延・同時書き込みの上限はここに仕込む。
    public nonisolated let server = FakeDropboxServer()

    struct Mount: Sendable {
        let member: String
        /// 受ける人から見えるパス（小文字）と表示名。
        let pathLower: String
        let display: String
        /// 全体のパス（小文字）。
        let target: String
        let owner: String
        let access: Access
    }
    private var mounts: [Mount] = []
    private var accounts: [String: FakeDropboxAccount] = [:]

    public init() {}

    static func home(_ id: String) -> String { "/~" + id.lowercased() }

    /// アカウントを作る（同じ ID なら同じものを返す）。
    public func account(_ id: String) async -> FakeDropboxAccount {
        if let existing = accounts[id] { return existing }
        let account = FakeDropboxAccount(id: id, cloud: self)
        accounts[id] = account
        await server.seed(Self.home(id), hash: "", isFolder: true)
        return account
    }

    /// `owner` の `folder` を `member` と共有する。受ける人の Dropbox ではルート直下に
    /// **フォルダ名で**現れる（同じ名前があれば `名前 (1)`）。現れたパスを返す。
    @discardableResult
    public func share(_ folder: String, of owner: String, with member: String,
                      access: Access = .viewer) async -> String {
        let target = Self.home(owner) + folder.lowercased()
        let isFolder = await server.entry(at: target)?.isFolder == true
        precondition(isFolder, "共有できるのは在るフォルダだけ（本物も同じ）: \(folder)")
        let base = (folder as NSString).lastPathComponent
        let taken = await rootNames(of: member)
        var name = base
        var n = 1
        while taken.contains(name.lowercased()) {
            name = "\(base) (\(n))"
            n += 1
        }
        mounts.append(Mount(member: member.lowercased(), pathLower: "/" + name.lowercased(),
                            display: "/" + name, target: target, owner: owner.lowercased(),
                            access: access))
        return "/" + name
    }

    /// 共有を外す（送る人が外した／受ける人が抜けた）。受ける人の Dropbox から消える。
    public func unshare(_ mountPath: String, from member: String) {
        mounts.removeAll { $0.member == member.lowercased() && $0.pathLower == mountPath.lowercased() }
    }

    private func rootNames(of member: String) async -> Set<String> {
        let home = Self.home(member)
        var names = Set(await server.filePaths(includingFolders: true)
            .filter { $0.hasPrefix(home + "/") && !$0.dropFirst(home.count + 1).contains("/") }
            .map { String($0.dropFirst(home.count + 1)) })
        for mount in mounts where mount.member == member.lowercased() {
            names.insert(String(mount.pathLower.dropFirst()))
        }
        return names
    }

    // MARK: - パスの書き換え

    /// アカウントから見えるパス → 全体のパス（小文字）と、通る共有フォルダ。
    func resolve(_ path: String, for member: String) -> (global: String, mount: Mount?) {
        let lower = path.lowercased()
        if lower.isEmpty || lower == "/" { return (Self.home(member), nil) }
        for mount in mounts where mount.member == member.lowercased()
            && (lower == mount.pathLower || lower.hasPrefix(mount.pathLower + "/")) {
            return (mount.target + lower.dropFirst(mount.pathLower.count), mount)
        }
        return (Self.home(member) + lower, nil)
    }

    /// 全体のパス → アカウントから見えるパス（見えなければ nil）。`display` は表示用の綴り。
    func localize(_ global: String, for member: String) -> (lower: String, display: String)? {
        let lower = global.lowercased()
        // 共有フォルダを先に見る（自分の名前空間の中を共有している場合もあるため長い方を優先）。
        for mount in mounts.sorted(by: { $0.target.count > $1.target.count })
            where mount.member == member.lowercased()
            && (lower == mount.target || lower.hasPrefix(mount.target + "/")) {
            let rest = String(global.dropFirst(mount.target.count))
            return (mount.pathLower + rest.lowercased(), mount.display + rest)
        }
        let home = Self.home(member)
        if lower == home { return ("", "") }
        if lower.hasPrefix(home + "/") {
            let rest = String(global.dropFirst(home.count))
            return (rest.lowercased(), rest)
        }
        return nil
    }

    /// 差分カーソルの根（全体のパス）が、この人にいま見えているか。
    func canSee(global root: String, for member: String) -> Bool {
        localize(root, for: member) != nil
    }

    func mountsVisible(to member: String) -> [Mount] {
        mounts.filter { $0.member == member.lowercased() }
    }
}

/// 1 つのアカウントとして話す `HTTPClient`。アプリのコードにはこれを渡す。
public actor FakeDropboxAccount: HTTPClient {
    public nonisolated let id: String
    private let cloud: FakeDropboxCloud

    /// このアカウントが投げた要求（エンドポイント・アカウントから見たパス）。
    public private(set) var requests: [(endpoint: String, paths: [String])] = []
    /// 共有されたフォルダ（他人のもの）へ書こうとした要求。⚠️ 受ける側のアプリは
    /// **他人の共有フォルダへ一切書かない**のが約束なので、テストはこれが空であることを見る。
    public private(set) var writesIntoShared: [String] = []
    /// 差分カーソルの札（アカウントへ渡す不透明な値 → 中身のカーソル）。本物のカーソルも
    /// 不透明で、中に全体のパスが見えることはない。
    private var cursorTokens: [String: String] = [:]

    init(id: String, cloud: FakeDropboxCloud) {
        self.id = id
        self.cloud = cloud
    }

    static let writeEndpoints = ["files/upload", "copy_batch_v2", "delete_batch",
                                 "files/move_v2", "create_folder_v2"]

    /// 書き込みの要求の数（「受けるだけの人は何も書かない」を数えるため）。
    public func writeCount() -> Int {
        requests.filter { r in Self.writeEndpoints.contains { r.endpoint.contains($0) } }.count
    }

    public func uploadCount() -> Int { requests.filter { $0.endpoint.contains("files/upload") }.count }

    // MARK: - テストの前提づくり（アカウントから見たパスで）

    public func upload(path: String, data: Data) async {
        await cloud.server.upload(path: await cloud.resolve(path, for: id).global, data: data)
    }

    public func makeFolder(_ path: String) async {
        await cloud.server.seed(await cloud.resolve(path, for: id).global, hash: "", isFolder: true)
    }

    /// 外部（Web・他の端末）からの削除。
    public func remove(_ path: String) async {
        await cloud.server.remove(await cloud.resolve(path, for: id).global)
    }

    /// このアカウントに見えるファイル（自分の名前空間＋共有されたフォルダ・小文字・昇順）。
    public func visibleFiles() async -> [String] {
        var out: [String] = []
        for path in await cloud.server.filePaths() {
            if let local = await cloud.localize(path, for: id) { out.append(local.lower) }
        }
        return out.sorted()
    }

    public func contentHash(at path: String) async -> String? {
        await cloud.server.contentHash(at: await cloud.resolve(path, for: id).global)
    }

    public func body(at path: String) async -> Data? {
        await cloud.server.body(at: await cloud.resolve(path, for: id).global)
    }

    // MARK: - HTTPClient

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!.absoluteString
        let endpoint = url.components(separatedBy: "/2/").last ?? url
        func respond(_ status: Int, _ body: String) -> (Data, URLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                              httpVersion: nil, headerFields: nil)!)
        }

        let header = request.value(forHTTPHeaderField: "Dropbox-API-Arg")
        let headerJSON = header.flatMap { Self.jsonObject(Data($0.utf8)) }
        var bodyJSON = request.httpBody.flatMap { Self.jsonObject($0) }
        if let token = bodyJSON?["cursor"] as? String, let real = cursorTokens[token] {
            bodyJSON?["cursor"] = real
        }
        let paths = Self.paths(in: headerJSON) + Self.paths(in: bodyJSON)
        requests.append((endpoint, paths.map(\.value)))

        if endpoint.contains("get_current_account") {
            return respond(200, #"{"account_id":"dbid:\#(id)","name":{"display_name":"\#(id)"}}"#)
        }

        // 書き込み先が他人の共有フォルダか（閲覧のみなら弾く）。
        if Self.writeEndpoints.contains(where: { endpoint.contains($0) }) {
            var denied = false
            for path in Self.writeTargets(endpoint: endpoint, paths) {
                let resolved = await cloud.resolve(path, for: id)
                guard let mount = resolved.mount else { continue }
                writesIntoShared.append(path.lowercased())
                if mount.access == .viewer { denied = true }
            }
            if denied {
                return respond(409, #"{"error":{".tag":"path","path":{".tag":"no_write_permission"}},"error_summary":"path/no_write_permission/"}"#)
            }
        }

        // 差分カーソル: 根が見えなくなっていたら `path/not_found`（共有を外された）。
        if endpoint.contains("list_folder/continue") || endpoint.contains("list_folder/longpoll") {
            if let cursor = bodyJSON?["cursor"] as? String, cursor.hasPrefix("rev-"),
               let bar = cursor.firstIndex(of: "|") {
                let root = String(cursor[cursor.index(after: bar)...])
                if !(await cloud.canSee(global: root, for: id)) {
                    return respond(409, #"{"error":{".tag":"path","path":{".tag":"not_found"}},"error_summary":"path/not_found/"}"#)
                }
            }
        }

        // アカウントのルート。
        let rootPath = (bodyJSON?["path"] as? String)?.lowercased()
        if endpoint.hasSuffix("files/list_folder"), rootPath == "" || rootPath == "/" {
            return try await listRoot(recursive: (bodyJSON?["recursive"] as? Bool) ?? false,
                                      respond: respond)
        }
        if endpoint.contains("get_latest_cursor"), rootPath == "" || rootPath == "/" {
            return respond(400, "fake: a delta cursor on the account root is not modeled")
        }

        // 要求のパスを全体のパスへ。
        var rewritten = request
        if let headerJSON {
            let mapped = await rewrite(headerJSON)
            rewritten.setValue(Self.string(mapped), forHTTPHeaderField: "Dropbox-API-Arg")
        }
        if let bodyJSON {
            rewritten.httpBody = Data(Self.string(await rewrite(bodyJSON)).utf8)
        }
        let (data, response) = try await cloud.server.data(for: rewritten)
        return (hideCursors(await localizeResponse(data)), response)
    }

    // MARK: - 書き換えの部品

    private static let deltaCursor = try! NSRegularExpression(pattern: #""cursor":"(rev-[^"]*)""#)

    /// 応答の差分カーソルを不透明な札に替える（同じカーソルには同じ札）。
    private func hideCursors(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        let ns = text as NSString
        guard let match = Self.deltaCursor.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        else { return data }
        let real = ns.substring(with: match.range(at: 1))
        let token = cursorTokens.first { $0.value == real }?.key ?? "cur-\(id)-\(cursorTokens.count + 1)"
        cursorTokens[token] = real
        return Data(ns.replacingCharacters(in: match.range(at: 1), with: token).utf8)
    }

    private static let pathKeys: Set<String> = ["path", "from_path", "to_path"]

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func string(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// JSON の中のパス（キーと値）。`entries` の配列も見る。
    private static func paths(in object: [String: Any]?) -> [(key: String, value: String)] {
        guard let object else { return [] }
        var out: [(String, String)] = []
        for (key, value) in object {
            if pathKeys.contains(key), let string = value as? String { out.append((key, string)) }
            if let array = value as? [[String: Any]] { array.forEach { out += paths(in: $0) } }
        }
        return out
    }

    /// 書き込み先（コピーなら宛先・移動なら両方・削除なら対象）。
    private static func writeTargets(endpoint: String,
                                     _ paths: [(key: String, value: String)]) -> [String] {
        if endpoint.contains("copy_batch") { return paths.filter { $0.key == "to_path" }.map(\.value) }
        return paths.map(\.value)
    }

    private func rewrite(_ object: [String: Any]) async -> [String: Any] {
        var out = object
        for (key, value) in object {
            if Self.pathKeys.contains(key), let string = value as? String {
                out[key] = await cloud.resolve(string, for: id).global
            } else if let array = value as? [[String: Any]] {
                var mapped: [[String: Any]] = []
                for item in array { mapped.append(await rewrite(item)) }
                out[key] = mapped
            }
        }
        return out
    }

    private static let pathField = try! NSRegularExpression(
        pattern: #""(path_lower|path_display)":"((?:[^"\\]|\\.)*)""#)

    /// 応答の `path_lower` / `path_display` をアカウントから見えるパスへ。
    private func localizeResponse(_ data: Data) async -> Data {
        let text = String(decoding: data, as: UTF8.self)
        let ns = text as NSString
        let matches = Self.pathField.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return data }
        var out = ""
        var cursor = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let key = ns.substring(with: match.range(at: 1))
            let value = ns.substring(with: match.range(at: 2))
            let local = await cloud.localize(value, for: id)
            let mapped = key == "path_lower" ? (local?.lower ?? value) : (local?.display ?? value)
            out += "\"\(key)\":\"\(mapped)\""
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return Data(out.utf8)
    }

    /// アカウントのルートの一覧（自分の名前空間＋共有されたフォルダ）を 1 ページで返す。
    private func listRoot(recursive: Bool,
                          respond: (Int, String) -> (Data, URLResponse)) async throws -> (Data, URLResponse) {
        var entries: [String] = []
        var roots = [FakeDropboxCloud.home(id)]
        for mount in await cloud.mountsVisible(to: id) {
            entries.append(#"{".tag":"folder","name":"\#((mount.display as NSString).lastPathComponent)","path_lower":"\#(mount.pathLower)","path_display":"\#(mount.display)","id":"id:\#(mount.target)"}"#)
            if recursive { roots.append(mount.target) }
        }
        for root in roots {
            entries += try await allEntries(globalRoot: root, recursive: recursive)
        }
        let joined = String(decoding: await localizeResponse(Data(entries.joined(separator: ",").utf8)),
                            as: UTF8.self)
        return respond(200, #"{"entries":[\#(joined)],"cursor":"root","has_more":false}"#)
    }

    private func allEntries(globalRoot: String, recursive: Bool) async throws -> [String] {
        struct Page: Decodable { let cursor: String; let has_more: Bool }
        var out: [String] = []
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/list_folder")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"path":"\#(globalRoot)","recursive":\#(recursive)}"#.utf8)
        while true {
            let (data, _) = try await cloud.server.data(for: request)
            guard let object = Self.jsonObject(data),
                  let raw = object["entries"] as? [[String: Any]] else { break }
            out += raw.compactMap { entry in
                (try? JSONSerialization.data(withJSONObject: entry, options: [.withoutEscapingSlashes]))
                    .map { String(decoding: $0, as: UTF8.self) }
            }
            guard (object["has_more"] as? Bool) == true, let next = object["cursor"] as? String else { break }
            request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/list_folder/continue")!)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"cursor":"\#(next)"}"#.utf8)
        }
        return out
    }
}
