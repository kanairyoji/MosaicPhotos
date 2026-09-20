import Foundation
import DropboxCore

/// **状態を持つ** Dropbox の偽サーバー（テスト専用）。
///
/// ## なぜ必要か
/// 従来のスタブは「決められた応答を順に返す」だけで、コピー・削除の結果が残らなかった。
/// しかし実機で起きた障害（重複約 1,300 件の生成・掃除の空回りループ）は、いずれも
/// **複数回の反映にまたがる**現象で、1 回の応答を検査するテストでは構造的に検出できない。
/// このサーバーはファイル表を保持し、`copy_batch` / `delete_batch` / `list_folder` を
/// 実際に反映するので、「反映を 2 回・3 回走らせたら収束するか」を検証できる。
///
/// ## 使い方（仕込みは 1 本のルール表）
/// ```swift
/// let server = FakeDropboxServer()
/// await server.upload(path: "/a.jpg", data: bytes)      // 置く
/// await server.inject(.init(endpoint: "files/upload",   // 仕込む
///                           pathContains: ".mosaic",
///                           times: 2,                    // -1 = ずっと
///                           effect: .status(429, retryAfter: 3)))
/// …
/// #expect(await server.pendingFaults().isEmpty)         // 仕込みが実際に使われたか
/// print(await server.transcript())                      // 落ちたとき何が起きたか
/// ```
/// 効果は `Effect` の 5 つ（HTTP エラー・本文の切れ・遅延・接続失敗・無応答）。
/// **新しい壊れ方は `Effect` に 1 行足す**——失敗の種類ごとにプロパティを増やさない。
///
/// ## ⚠️ Dropbox の偽物は**これ 1 つ**にする（2026-09-20 に統合）
/// かつては用途ごとに簡易スタブが 5 つ併存していた（`FakeDropbox` / `RecordingDropbox` /
/// `MarkerRecorder` / `StatefulShardServer` / `Fake`）。忠実度がまちまちで、
/// **弱い偽物は経路をまるごと隠す**——同じ日に 2 回踏んだ:
///   - `get_metadata` が `size` を常に 1 で返し、**オフロードの照合が必ず失敗**していた
///     （＝オフロードの流れをどのテストも通れなかった）
///   - `files/upload` が `mode=add` を無視して上書きし、**同名衝突（409→autorename）の
///     経路が存在しなかった**
/// 1 つに寄せてあれば、忠実度の不足を直した瞬間に**全テストへ効く**。
/// 新しい振る舞いが要るときは、ここへ足すこと（別の偽物を作らない）。
///
/// 例外: **リクエスト/レスポンス 1 回ぶんを検査する**スタブは別でよい
/// （`BackupEngineUploadTests` の応答分類、`ShareCopierTests` の応答列）。
/// あれらは「状態」ではなく「1 往復の組み立てと解釈」を見ている。
///
/// ## 再現できる実障害
/// - `jobsTimeOutButComplete`: **クライアントにはタイムアウトを返すが、サーバー側では完了する**
///   非同期ジョブ（diagnostics-52 の暴走の引き金そのもの）。
/// - `rateLimitEveryNthRequest`: 429（diagnostics-54 で疑われたレート制限）。
/// - `failCopyPaths`: 特定のコピーだけ失敗させる（部分失敗の扱いを検証）。
public actor FakeDropboxServer: HTTPClient {

    public struct Entry: Equatable {
        var contentHash: String
        var isFolder: Bool
        var rev: String
        /// 表示名（**元の大文字小文字を保つ**）。本物の `name` は path_lower と違う。
        public var displayName: String = ""
        /// ファイルサイズ（`get_metadata` が返す）。
        /// ⚠️ **本物と同じ値を返すこと**。ここを固定値にしていたため、オフロードの照合
        /// （hash ＋ **サイズ**の完全一致）がこの偽サーバーでは必ず落ち、オフロードの流れを
        /// 一度も通せなかった（「印を書いて、読み直す」の検証ができなかった）。
        var size: Int = 1
    }

    /// path_lower → エントリ。
    public private(set) var files: [String: Entry] = [:]
    /// path_lower → アップロードされた本体（download で返す）。
    /// 「上げたものが、そのまま取り出せるか」＝オフロード後の復元忠実性を検証するため。
    private var bodies: [String: Data] = [:]
    /// 発行済みリクエストの記録（呼ばれ方の検証用）。
    public private(set) var requestLog: [String] = []

    // MARK: - 観測（テストが落ちたときに「何が起きたか」を読めるように）

    /// 1 往復の記録。`transcript()` で人が読める形にする。
    public struct Exchange: Sendable {
        public let endpoint: String
        public let path: String
        public let status: Int
        public let sentBytes: Int
        public let receivedBytes: Int
    }
    public private(set) var exchanges: [Exchange] = []

    /// **人が読める通信記録**。テストが落ちたとき、これを出せば何を何回呼んだかが分かる。
    /// 例: `POST files/upload /a.jpg → 200 (12 B ↑ / 48 B ↓)`
    public func transcript() -> String {
        exchanges.map {
            "POST \($0.endpoint) \($0.path.isEmpty ? "-" : $0.path) → \($0.status) "
            + "(\($0.sentBytes) B ↑ / \($0.receivedBytes) B ↓)"
        }.joined(separator: "\n")
    }

    /// エンドポイント別の呼び出し回数。**回数で見る**規模テスト（ADR-119）にそのまま使える。
    public func callCounts() -> [String: Int] {
        exchanges.reduce(into: [:]) { $0[$1.endpoint, default: 0] += 1 }
    }

    /// 送受信の合計バイト数。「回数は同じだが量が増えた」を捕まえる。
    public func trafficBytes() -> (sent: Int, received: Int) {
        (exchanges.reduce(0) { $0 + $1.sentBytes }, exchanges.reduce(0) { $0 + $1.receivedBytes })
    }

    /// いまサーバーに在るものを 1 行ずつ（収束しないテストの原因調査用）。
    public func dump() -> String {
        files.sorted { $0.key < $1.key }.map { path, entry in
            entry.isFolder ? "DIR  \(path)"
                           : "FILE \(path)  \(entry.size) B  \(entry.contentHash.prefix(12))…"
        }.joined(separator: "\n")
    }
    private var jobCounter = 0
    /// 完了待ちジョブ（check で返す結果）。
    private var pendingJobs: [String: String] = [:]
    private var requestCount = 0
    /// `list_folder` の 1 ページの件数（本物は最大 2,000）。小さくしてページングを踏ませる。
    private var pageSize = 2_000
    /// 発行済みカーソル → 残りのエントリ（JSON 文字列）。**1 回の一覧のページ送り**用。
    private var cursors: [String: [String]] = [:]
    private var cursorCounter = 0

    // MARK: - 差分同期（longpoll → continue）

    /// 変更の通し番号。ファイルが増減・変化するたびに進む。
    private var revision = 0
    /// 変更の履歴（通し番号・パス・消えたか）。`continue` が「この番号より後」を返す。
    private var changeLog: [(revision: Int, path: String, deleted: Bool)] = []

    /// 変更を 1 件記録する（`upload` / `remove` / コピー・削除・移動から呼ぶ）。
    private func note(_ path: String, deleted: Bool) {
        revision += 1
        changeLog.append((revision, path.lowercased(), deleted))
    }

    /// 差分カーソル（`rev-<n>`）が指す番号。ページ送りカーソルと混ざらないよう接頭辞で分ける。
    private static func deltaRevision(of cursor: String) -> Int? {
        cursor.hasPrefix("rev-") ? Int(cursor.dropFirst(4)) : nil
    }

    // MARK: - 障害注入

    /// 非同期ジョブを「クライアントには in_progress を返し続ける（＝タイムアウトさせる）」が、
    /// **サーバー側の効果は即座に適用**する。実機の暴走を正確に再現するための設定。
    public var jobsTimeOutButComplete = false
    /// N 回に 1 回 429 を返す（0 で無効）。
    public var rateLimitEveryNthRequest = 0
    /// この接頭辞に一致するコピー先は失敗させる。
    var failCopyPaths: Set<String> = []
    /// このパスの削除を失敗させる（no_permission 相当＝「無い」ではない本物の失敗）。
    var failDeletePaths: Set<String> = []
    /// move_v2 を通信エラー（500）にする。「通信断で改名できない回」を再現するため。
    public var failMove = false

    /// **狙ったパスだけを、狙った回数だけ失敗させる**（オフロードの検証用）。
    ///
    /// ⚠️ なぜ「回数」が要るか: オフロードは**写真を消してから**印を書くので、
    /// 印が書けなかった回に大事なのは「失敗したこと」ではなく**そのあと収束するか**。
    /// 恒久的な失敗しか作れないと、「再送で最終的に届く」を確かめられない。
    ///
    /// ## 注入は**1 本のルール表**（`inject`）
    /// 「どのエンドポイントの・どのパスに・何回・何を起こすか」を 1 行で書く。
    /// ⚠️ 失敗の種類ごとにプロパティとセッターを足す作りは、**同じ増え方を繰り返す**
    /// （ADR-196 でゲート判定を 11 の述語から 1 つの表へ畳んだのと同じ話）。
    /// 新しい失敗が要るときは `Effect` に 1 行足すだけで済むようにしておく。
    public struct Fault: Equatable, Sendable {
        /// 対象のエンドポイント（`files/upload` 等）。nil＝すべて。
        public var endpoint: String?
        /// 対象のパスに含まれる語。nil または空＝パスで絞らない。
        public var pathContains: String?
        /// 適用する回数（-1＝ずっと）。**「何回目までは失敗するが、その後は通る」**を作れる
        /// ことが要点——恒久的な失敗しか作れないと収束を確かめられない。
        public var times: Int
        public var effect: Effect

        public init(endpoint: String? = nil, pathContains: String? = nil,
                    times: Int = -1, effect: Effect) {
            self.endpoint = endpoint
            self.pathContains = pathContains
            self.times = times
            self.effect = effect
        }

        func matches(endpoint requested: String, path: String) -> Bool {
            if let endpoint, !requested.contains(endpoint) { return false }
            if let pathContains, !pathContains.isEmpty,
               !path.lowercased().contains(pathContains.lowercased()) { return false }
            return times != 0
        }
    }

    /// 起こせること。**新しい壊れ方はここへ 1 行足す**（プロパティを増やさない）。
    public enum Effect: Equatable, Sendable {
        /// HTTP エラー。`retryAfter` を付けると `Retry-After` ヘッダも返す。
        case status(Int, retryAfter: Int? = nil)
        /// HTTP 200 だが**本文が途中で切れる**（「成功したのに中身が違う」）。
        case truncateBody
        /// 応答をこのミリ秒だけ遅らせる（失敗ではない・そのあと通常の応答）。
        case delay(milliseconds: Int)
        /// 接続そのものが失敗する（`URLError`）。
        case networkError
        /// **応答を返さない**（呼び出し側のタイムアウト・キャンセルを試す）。
        /// ⚠️ キャンセルされるまで戻らないので、キャンセルの効かない呼び出しでは止まる。
        case drop
    }

    private var faults: [Fault] = []

    /// 失敗（や遅延）を 1 つ仕込む。
    public func inject(_ fault: Fault) { faults.append(fault) }

    /// **まだ使われていないルール**。⚠️ 「起こしたはずの失敗が実は起きていなかった」を
    /// 見つけるために使う——テストが緑でも、経路を通っていなければ何も確かめていない。
    public func pendingFaults() -> [Fault] { faults.filter { $0.times != 0 } }

    /// 仕込んだものをすべて解除する（「レート制限が明けた」「権限が戻った」を作る）。
    public func clearFaults() {
        faults.removeAll()
        rateLimitEveryNthRequest = 0
    }

    /// 該当するルールを 1 つ消費して返す（回数を 1 減らす）。
    private func consumeFault(endpoint: String, path: String) -> Effect? {
        guard let index = faults.firstIndex(where: { $0.matches(endpoint: endpoint, path: path) })
        else { return nil }
        if faults[index].times > 0 { faults[index].times -= 1 }
        return faults[index].effect
    }

    // MARK: - 別名（読みやすさのため・中身は `inject` 1 つ）

    /// `files/upload` のうち、パスにこの語を含むものを失敗させる。
    public func failUploads(matching fragment: String, status: Int = 429, times: Int = -1) {
        inject(.init(endpoint: "files/upload", pathContains: fragment, times: times,
                     effect: .status(status)))
    }

    /// `files/get_metadata` のうち、パスにこの語を含むものを失敗させる。
    /// オフロードの**照合**（hash・サイズ）が取れない回を作るために使う。
    public func failGetMetadata(matching fragment: String, status: Int = 429, times: Int = -1) {
        inject(.init(endpoint: "get_metadata", pathContains: fragment, times: times,
                     effect: .status(status)))
    }

    /// `files/download` のうち、パスにこの語を含むものを失敗させる。
    /// ⚠️ メタデータの読み書きで「**無い**」と「**取れなかった**」を区別できているかを見るために要る
    /// （取れなかった回に空として上書きすると、その月の記録が丸ごと消える）。
    public func failDownloads(matching fragment: String, status: Int = 401, times: Int = -1) {
        inject(.init(endpoint: "files/download", pathContains: fragment, times: times,
                     effect: .status(status)))
    }

    /// `list_folder/continue`（2 ページ目以降）を失敗させる。
    /// ⚠️ 照合は「一覧が全部取れたこと」が前提で、**途中で失敗した回に 1 ページ目を全部と
    /// 読むと、残り全部の記録が消える**（オフロード済みなら写真がアプリから消える）。
    public func setFailListFolderContinue(_ value: Bool) {
        if value {
            inject(.init(endpoint: "list_folder/continue", effect: .status(500)))
        } else {
            faults.removeAll { $0.endpoint == "list_folder/continue" }
        }
    }

    /// このパス片を含むダウンロードの本文を**途中で切る**（中身が壊れた応答）。
    public func truncateDownloads(matching fragment: String) {
        inject(.init(endpoint: "files/download", pathContains: fragment, effect: .truncateBody))
    }

    /// 旧名（`clearFaults` と同じ）。
    public func clearFailures() { clearFaults() }

    /// A2: `copy_batch` / `delete_batch` の非同期ジョブを、**この回数だけ** `in_progress` にする
    /// （0＝即完了）。本番の共有反映はここを通るのに、遅延完了を一度も試していなかった。
    public private(set) var asyncJobChecksBeforeComplete = 0
    public func setAsyncJobChecks(_ count: Int) { asyncJobChecksBeforeComplete = max(0, count) }
    /// ジョブ ID → 残りの `in_progress` 回数。
    private var jobChecksRemaining: [String: Int] = [:]

    /// A4: 空き容量（バイト）。これを超えるアップロードは `insufficient_space`。-1＝無制限。
    public private(set) var freeSpaceBytes = -1
    public func setFreeSpace(bytes: Int) { freeSpaceBytes = bytes }

    /// B3: このアカウントとして振る舞う（`get_current_account`）。
    public private(set) var accountID = "acct-fake"
    public func setAccountID(_ id: String) { accountID = id }

    /// B4: 発行済みカーソルを失効させる（次の `continue` は `reset` を返す）。
    /// Dropbox は稀にこれを返し、アプリは**初回同期からやり直す**必要がある。
    public private(set) var cursorsExpired = false
    public func expireCursors() { cursorsExpired = true }
    public func restoreCursors() { cursorsExpired = false }

    /// B5: 一覧が返す `server_modified` をこの時刻にする（端末との時計のずれを作る）。
    public private(set) var serverModified = Date(timeIntervalSince1970: 1_700_000_000)
    public func setServerModified(_ date: Date) { serverModified = date }
    private var serverModifiedString: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: serverModified)
    }

    /// B2: すべての応答をこのミリ秒だけ遅らせる。
    public private(set) var responseDelay = 0
    public func setResponseDelay(milliseconds: Int) { responseDelay = max(0, milliseconds) }

    /// A1: 429 に `Retry-After`（秒）を付ける。0＝付けない。
    /// ⚠️ アプリは**このヘッダを読む**実装を持っているのに、付けない偽物しか無かったため
    /// その経路を一度も通していなかった。
    public private(set) var retryAfterSeconds = 0
    public func setRetryAfter(seconds: Int) { retryAfterSeconds = max(0, seconds) }

    /// A5: 429 の種類を「名前空間の書き込み競合」にする（待てば通る種類）。
    public private(set) var rateLimitIsWriteConflict = false
    public func setRateLimitIsWriteConflict(_ value: Bool) { rateLimitIsWriteConflict = value }

    private func rateLimited(_ resp: (Int, String, [String: String]) -> (Data, URLResponse))
        -> (Data, URLResponse) {
        let summary = rateLimitIsWriteConflict
            ? #"{"error_summary":"too_many_write_operations/.."}"#
            : #"{"error_summary":"too_many_requests/.."}"#
        let headers = retryAfterSeconds > 0 ? ["Retry-After": "\(retryAfterSeconds)"] : [:]
        return resp(429, summary, headers)
    }

    /// Dropbox が返すエラー本文（要約はアプリのログにそのまま出る）。
    private static func errorBody(_ status: Int) -> String {
        switch status {
        case 429: return #"{"error_summary":"too_many_write_operations/.."}"#
        case 403: return #"{"error_summary":"insufficient_permissions/.."}"#
        case 401: return #"{"error_summary":"expired_access_token/.."}"#
        default:  return #"{"error_summary":"internal_error/.."}"#
        }
    }

    public init(files: [String: Entry] = [:]) { self.files = files }

    /// 既存ファイルを直接置く（テストの前提条件づくり）。
    public func seed(_ path: String, hash: String, isFolder: Bool = false, size: Int = 1) {
        files[path.lowercased()] = Entry(contentHash: hash, isFolder: isFolder,
                                         rev: "r\(files.count)",
                                         displayName: (path as NSString).lastPathComponent,
                                         size: size)
    }

    /// 中身つきでファイルを置く（他端末がアップロードした解析データ等を模す）。content_hash は本物と同じ計算。
    public func upload(path: String, data: Data) {
        let key = path.lowercased()
        note(key, deleted: false)
        bodies[key] = data
        files[key] = Entry(contentHash: DropboxContentHash.hash(of: data), isFolder: false,
                           rev: "r\(files.count)",
                           displayName: (path as NSString).lastPathComponent, size: data.count)
    }

    /// 外部（他端末・Dropbox の Web UI）からの削除を模す。
    public func remove(_ path: String) {
        files.removeValue(forKey: path.lowercased())
        note(path, deleted: true)
    }

    /// 現在のファイル一覧（フォルダを除く・パス昇順）。
    public func filePaths() -> [String] {
        files.filter { !$0.value.isFolder }.keys.sorted()
    }

    /// そのパスに**いま置かれている中身**（アップロードされたもの・seed した本体）。
    /// 「書いた JSON が意図どおりか」を確かめるのに使う。
    public func body(at path: String) -> Data? { bodies[path.lowercased()] }

    /// アップロードが要求された順のパス一覧（**失敗した回も含む**）。
    /// 「何回・どの順で送ったか」を数えるために使う（ADR-119 の考え方＝回数で見る）。
    public private(set) var uploadedPaths: [String] = []

    /// アップロード（`files/upload`）の回数。「無駄に上げ直していないか」の検証用。
    /// ⚠️ 結果（ファイルの有無）だけを見ると、毎回上げ直す実装でも通ってしまう。
    public func uploadCount() -> Int {
        requestLog.filter { $0.contains("files/upload") }.count
    }

    public func setJobsTimeOutButComplete(_ value: Bool) { jobsTimeOutButComplete = value }
    public func setRateLimit(everyNth: Int) { rateLimitEveryNthRequest = everyNth }
    public func setFailCopyPaths(_ paths: Set<String>) { failCopyPaths = paths }
    public func setFailDeletePaths(_ paths: Set<String>) { failDeletePaths = paths }
    public func setFailMove(_ value: Bool) { failMove = value }
    /// ページングを踏ませる（本物は 2,000 件/ページ・`has_more` と `list_folder/continue`）。
    public func setPageSize(_ value: Int) { pageSize = max(1, value) }

    // MARK: - HTTPClient

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        // ⚠️ **仕込んだ失敗の判定はここ 1 か所**（各ハンドラへ if を散らさない）。
        let endpoint = Self.endpoint(of: request)
        let path = Self.argPath(of: request)
        var truncate = false
        if let effect = consumeFault(endpoint: endpoint, path: path) {
            switch effect {
            case .status(let code, let retryAfter):
                let headers = retryAfter.map { ["Retry-After": "\($0)"] } ?? [:]
                let response = HTTPURLResponse(url: request.url!, statusCode: code,
                                               httpVersion: nil, headerFields: headers)!
                let body = Data(Self.errorBody(code).utf8)
                exchanges.append(Exchange(endpoint: endpoint, path: path, status: code,
                                          sentBytes: (request.httpBody ?? Data()).count,
                                          receivedBytes: body.count))
                return (body, response)
            case .networkError:
                throw URLError(.networkConnectionLost)
            case .drop:
                // キャンセルされるまで戻らない（呼び出し側のタイムアウトを試すため）。
                try await Task.sleep(for: .seconds(3600))
                throw CancellationError()
            case .delay(let milliseconds):
                try? await Task.sleep(for: .milliseconds(milliseconds))
            case .truncateBody:
                truncate = true
            }
        }
        var result = try await route(request)
        if truncate {
            // 「HTTP 200 なのに中身が途中で切れている」＝hash 照合が働くかを見るため。
            result.0 = result.0.prefix(max(0, result.0.count / 2))
        }
        // 観測（C1/C2/C4）: 1 往復ぶんを記録する。
        exchanges.append(Exchange(
            endpoint: endpoint, path: path,
            status: (result.1 as? HTTPURLResponse)?.statusCode ?? -1,
            sentBytes: (request.httpBody ?? Data()).count,
            receivedBytes: result.0.count))
        return result
    }

    /// URL から `files/upload` のようなエンドポイント名を取る。
    private static func endpoint(of request: URLRequest) -> String {
        let url = request.url!.absoluteString
        return url.components(separatedBy: "/2/").last ?? url
    }

    /// リクエストが指しているパス（`Dropbox-API-Arg` か本文の `path`）。
    private static func argPath(of request: URLRequest) -> String {
        struct Arg: Decodable { let path: String? }
        let raw = request.value(forHTTPHeaderField: "Dropbox-API-Arg")
            ?? String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "{}"
        return (try? JSONDecoder().decode(Arg.self, from: Data(raw.utf8)))?.path ?? ""
    }

    private func route(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!.absoluteString
        requestCount += 1
        requestLog.append(url)

        func resp(_ code: Int, _ body: String, headers: [String: String] = [:])
            -> (Data, URLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code,
                                              httpVersion: nil, headerFields: headers)!)
        }
        // B2: 遅い応答（タイムアウト・並行数・待ち行列の挙動を試すため）。
        if responseDelay > 0 { try? await Task.sleep(for: .milliseconds(responseDelay)) }
        // 既存ハンドラは「状態＋本文」の 2 引数版を受け取る（ヘッダ付きは 429 だけで使う）。
        let plain: (Int, String) -> (Data, URLResponse) = { resp($0, $1) }
        if rateLimitEveryNthRequest > 0, requestCount % rateLimitEveryNthRequest == 0 {
            return rateLimited(resp)
        }

        let body = request.httpBody ?? Data()
        if url.contains("create_folder_v2") { return handleCreateFolder(body, plain) }
        if url.contains("copy_batch/check_v2") || url.contains("delete_batch/check") {
            return handleCheck(body, plain)
        }
        if url.contains("files/move_v2")  { return handleMove(body, plain) }
        if url.contains("copy_batch_v2") { return handleCopyBatch(body, plain) }
        if url.contains("delete_batch")  { return handleDeleteBatch(body, plain) }
        if url.contains("get_current_account") {
            return resp(200, #"{"account_id":"\#(accountID)","name":{"display_name":"Fake"}}"#)
        }
        if url.contains("list_folder/get_latest_cursor") {
            // 「いまの状態」を指すカーソル。以後の `continue` はここから先の変更だけを返す。
            return resp(200, #"{"cursor":"rev-\#(revision)"}"#)
        }
        if url.contains("list_folder/longpoll") {
            // 本物は変更があるまで待つ。偽物は**その場で答える**（テストを待たせない）。
            struct Body: Decodable { let cursor: String }
            let cursor = (try? JSONDecoder().decode(Body.self, from: body))?.cursor ?? ""
            let since = Self.deltaRevision(of: cursor) ?? revision
            return resp(200, #"{"changes":\#(revision > since ? "true" : "false")}"#)
        }
        if url.contains("list_folder/continue") { return handleListFolderContinue(body, plain) }
        if url.contains("list_folder")   { return handleListFolder(body, plain) }
        if url.contains("get_metadata")  { return handleGetMetadata(body, plain) }
        if url.contains("files/upload")  { return handleUpload(request, plain) }
        if url.contains("files/download") { return handleDownload(request, plain) }
        return resp(400, #"{"error_summary":"unsupported_endpoint/"}"#)
    }

    // MARK: - エンドポイント

    private func handleCreateFolder(_ body: Data, _ resp: (Int, String) -> (Data, URLResponse))
        -> (Data, URLResponse) {
        struct Body: Decodable { let path: String }
        guard let parsed = try? JSONDecoder().decode(Body.self, from: body) else {
            return resp(400, "{}")
        }
        let key = parsed.path.lowercased()
        if files[key] != nil { return resp(409, #"{"error_summary":"path/conflict/folder/"}"#) }
        files[key] = Entry(contentHash: "", isFolder: true, rev: "d\(files.count)")
        return resp(200, "{}")
    }

    /// `files/move_v2`。フォルダ移動は配下ごと動く（本番と同じ）。
    private func handleMove(_ body: Data, _ resp: (Int, String) -> (Data, URLResponse))
        -> (Data, URLResponse) {
        struct Body: Decodable { let from_path: String; let to_path: String }
        guard let parsed = try? JSONDecoder().decode(Body.self, from: body) else {
            return resp(400, "{}")
        }
        if failMove { return resp(500, "{}") }
        let from = parsed.from_path.lowercased()
        let to = parsed.to_path.lowercased()
        guard files[from] != nil else {
            return resp(409, #"{"error_summary":"from_lookup/not_found/"}"#)
        }
        guard files[to] == nil else {
            return resp(409, #"{"error_summary":"to/conflict/folder/"}"#)
        }
        for (path, entry) in files where path == from || path.hasPrefix(from + "/") {
            files.removeValue(forKey: path)
            files[to + String(path.dropFirst(from.count))] = entry
        }
        return resp(200, #"{"metadata":{"path_lower":"\#(to)"}}"#)
    }

    private func handleCopyBatch(_ body: Data, _ resp: (Int, String) -> (Data, URLResponse))
        -> (Data, URLResponse) {
        struct Path: Decodable { let from_path: String; let to_path: String }
        struct Body: Decodable { let entries: [Path]; let autorename: Bool }
        guard let parsed = try? JSONDecoder().decode(Body.self, from: body) else {
            return resp(400, "{}")
        }

        var results: [String] = []
        for entry in parsed.entries {
            let from = entry.from_path.lowercased()
            var to = entry.to_path.lowercased()
            guard let source = files[from], !source.isFolder else {
                results.append(#"{".tag":"failure","failure":{".tag":"relocation_error"}}"#)
                continue
            }
            if failCopyPaths.contains(to) {
                results.append(#"{".tag":"failure","failure":{".tag":"relocation_error"}}"#)
                continue
            }
            if files[to] != nil {
                guard parsed.autorename else {
                    // autorename 無効なら衝突は失敗（本番と同じ挙動）。
                    results.append(#"{".tag":"failure","failure":{".tag":"to/conflict/file/"}}"#)
                    continue
                }
                to = Self.autorenamed(to, existing: Set(files.keys))
            }
            files[to] = Entry(contentHash: source.contentHash, isFolder: false,
                              rev: "r\(files.count)")
            bodies[to] = bodies[from]
            results.append(#"{".tag":"success","success":{".tag":"file","path_lower":"\#(to)","content_hash":"\#(source.contentHash)"}}"#)
        }
        return finishBatch(results: results, resp: resp)
    }

    private func handleDeleteBatch(_ body: Data, _ resp: (Int, String) -> (Data, URLResponse))
        -> (Data, URLResponse) {
        struct Arg: Decodable { let path: String }
        struct Body: Decodable { let entries: [Arg] }
        guard let parsed = try? JSONDecoder().decode(Body.self, from: body) else {
            return resp(400, "{}")
        }
        var results: [String] = []
        for entry in parsed.entries {
            let key = entry.path.lowercased()
            if failDeletePaths.contains(key) {
                // 権限不足など「消せなかった」失敗。**not_found とは意味が違う**。
                results.append(#"{".tag":"failure","failure":{".tag":"path_write","path_write":{".tag":"no_write_permission"}}}"#)
                continue
            }
            if files[key] == nil {
                results.append(#"{".tag":"failure","failure":{".tag":"path_lookup","path_lookup":{".tag":"not_found"}}}"#)
                continue
            }
            // フォルダ削除は配下ごと消える（本番と同じ）。
            if files[key]?.isFolder == true {
                for path in files.keys where path == key || path.hasPrefix(key + "/") {
                    files.removeValue(forKey: path)
                    bodies.removeValue(forKey: path)
                }
            } else {
                files.removeValue(forKey: key)
                bodies.removeValue(forKey: key)
            }
            results.append(#"{".tag":"success","success":{"metadata":{".tag":"file","path_lower":"\#(key)"}}}"#)
        }
        return finishBatch(results: results, resp: resp)
    }

    /// 非同期ジョブの表現。`jobsTimeOutButComplete` のときは**効果を適用済みのまま**
    /// クライアントには終わらない仕事として見せる（実障害の再現）。
    private func finishBatch(results: [String],
                             resp: (Int, String) -> (Data, URLResponse)) -> (Data, URLResponse) {
        let complete = #"{".tag":"complete","entries":[\#(results.joined(separator: ","))]}"#
        // A2: 正常な**遅延完了**（N 回 in_progress を返してから complete）。
        // 本番の共有反映はここを通るのに、以前は「即完了」か「永遠に未完了」しか作れなかった。
        if asyncJobChecksBeforeComplete > 0, !jobsTimeOutButComplete {
            jobCounter += 1
            let jobID = "job\(jobCounter)"
            pendingJobs[jobID] = complete
            jobChecksRemaining[jobID] = asyncJobChecksBeforeComplete
            return resp(200, #"{".tag":"async_job_id","async_job_id":"\#(jobID)"}"#)
        }
        guard jobsTimeOutButComplete else { return resp(200, complete) }
        jobCounter += 1
        let jobID = "job\(jobCounter)"
        pendingJobs[jobID] = complete   // 効果は既に適用済み・クライアントには進行中を返し続ける
        return resp(200, #"{".tag":"async_job_id","async_job_id":"\#(jobID)"}"#)
    }

    private func handleCheck(_ body: Data, _ resp: (Int, String) -> (Data, URLResponse))
        -> (Data, URLResponse) {
        struct Body: Decodable { let async_job_id: String? }
        let jobID = (try? JSONDecoder().decode(Body.self, from: body))?.async_job_id ?? ""
        // 遅延完了（A2）: 残り回数を 1 つ減らし、0 になったら結果を返す。
        if let remaining = jobChecksRemaining[jobID] {
            if remaining > 1 {
                jobChecksRemaining[jobID] = remaining - 1
                return resp(200, #"{".tag":"in_progress"}"#)
            }
            jobChecksRemaining[jobID] = nil
            if let complete = pendingJobs.removeValue(forKey: jobID) { return resp(200, complete) }
        }
        // タイムアウト再現中は永遠に in_progress を返す。
        return resp(200, #"{".tag":"in_progress"}"#)
    }

    private func handleListFolder(_ body: Data, _ resp: (Int, String) -> (Data, URLResponse))
        -> (Data, URLResponse) {
        struct Body: Decodable { let path: String?; let recursive: Bool? }
        let parsed = try? JSONDecoder().decode(Body.self, from: body)
        let root = (parsed?.path ?? "").lowercased()
        let recursive = parsed?.recursive ?? false
        if !root.isEmpty, files[root] == nil {
            return resp(409, #"{"error_summary":"path/not_found/"}"#)
        }
        // 直下のみ（非再帰）／配下ごと（再帰・ADR-183）。
        var listed = files.filter { path, _ in
            guard path != root, path.hasPrefix(root + "/") else { return false }
            return recursive || !path.dropFirst(root.count + 1).contains("/")
        }
        // 本物の Dropbox は**中間フォルダのエントリを必ず含む**（copy_batch でファイルを置いた
        // だけでも親フォルダは一覧に出る）。seed/create していない親を補う。
        if recursive {
            for path in Array(listed.keys) {
                var parent = (path as NSString).deletingLastPathComponent
                while parent.count > root.count, listed[parent] == nil {
                    listed[parent] = Entry(contentHash: "", isFolder: true, rev: "")
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
        }
        let entries = listed.sorted { $0.key < $1.key }
            .map { path, entry -> String in
                let name = entry.displayName.isEmpty
                    ? (path as NSString).lastPathComponent : entry.displayName
                let tag = entry.isFolder ? "folder" : "file"
                return #"{".tag":"\#(tag)","name":"\#(name)","path_lower":"\#(path)","rev":"\#(entry.rev)","content_hash":"\#(entry.contentHash)","server_modified":"\#(serverModifiedString)"}"#
            }
        return page(entries, resp)
    }

    private func handleListFolderContinue(_ body: Data, _ resp: (Int, String) -> (Data, URLResponse))
        -> (Data, URLResponse) {
        struct Body: Decodable { let cursor: String }
        guard let parsed = try? JSONDecoder().decode(Body.self, from: body) else {
            return resp(409, #"{"error_summary":"reset/"}"#)
        }
        // B4: 失効したカーソル。本物も稀に返す＝アプリは初回同期からやり直す必要がある。
        if cursorsExpired { return resp(409, #"{"error_summary":"reset/.."}"#) }
        // (a) 差分カーソル（`rev-<n>`）＝「この番号より後の変更」を返す。
        if let since = Self.deltaRevision(of: parsed.cursor) {
            var latest: [String: Bool] = [:]        // path → 消えたか（同じパスは最後の状態）
            for change in changeLog where change.revision > since {
                latest[change.path] = change.deleted
            }
            let entries = latest.sorted { $0.key < $1.key }.map { path, deleted -> String in
                if deleted { return #"{".tag":"deleted","path_lower":"\#(path)"}"# }
                let entry = files[path]
                let name = (path as NSString).lastPathComponent
                return #"{".tag":"file","name":"\#(name)","path_lower":"\#(path)","rev":"\#(entry?.rev ?? "r")","content_hash":"\#(entry?.contentHash ?? "")"}"#
            }
            return resp(200, #"{"entries":[\#(entries.joined(separator: ","))],"cursor":"rev-\#(revision)","has_more":false}"#)
        }
        // (b) ページ送りカーソル＝1 回の一覧の続き。
        guard let remaining = cursors.removeValue(forKey: parsed.cursor) else {
            return resp(409, #"{"error_summary":"reset/"}"#)
        }
        return page(remaining, resp)
    }

    /// 1 ページ返し、残りはカーソルに預ける（本物の `has_more` / `list_folder/continue` と同じ形）。
    private func page(_ entries: [String], _ resp: (Int, String) -> (Data, URLResponse)) -> (Data, URLResponse) {
        let head = Array(entries.prefix(pageSize))
        let rest = Array(entries.dropFirst(pageSize))
        cursorCounter += 1
        let cursor = "c\(cursorCounter)"
        if !rest.isEmpty { cursors[cursor] = rest }
        return resp(200, #"{"entries":[\#(head.joined(separator: ","))],"cursor":"\#(cursor)","has_more":\#(rest.isEmpty ? "false" : "true")}"#)
    }

    private func handleGetMetadata(_ body: Data, _ resp: (Int, String) -> (Data, URLResponse))
        -> (Data, URLResponse) {
        struct Body: Decodable { let path: String }
        guard let parsed = try? JSONDecoder().decode(Body.self, from: body) else {
            return resp(400, "{}")
        }
        guard let entry = files[parsed.path.lowercased()] else {
            return resp(409, #"{"error_summary":"path/not_found/"}"#)
        }
        return resp(200, #"{"content_hash":"\#(entry.contentHash)","size":\#(entry.size)}"#)
    }

    private func handleUpload(_ request: URLRequest, _ resp: (Int, String) -> (Data, URLResponse))
        -> (Data, URLResponse) {
        struct Arg: Decodable {
            let path: String
            let mode: String?
            let autorename: Bool?
        }
        guard let header = request.value(forHTTPHeaderField: "Dropbox-API-Arg"),
              let arg = try? JSONDecoder().decode(Arg.self, from: Data(header.utf8)) else {
            return resp(400, "{}")
        }
        var key = arg.path.lowercased()
        uploadedPaths.append(key)
        let body = request.httpBody ?? Data()
        // A4: 空き容量が足りなければ 507（Dropbox は insufficient_space を返す）。
        if freeSpaceBytes >= 0, body.count > freeSpaceBytes {
            return resp(507, #"{"error_summary":"path/insufficient_space/.."}"#)
        }
        // 本物と同じ content_hash を返す（アップロードの検証経路をそのまま通せる）。
        let hash = DropboxContentHash.hash(of: body)
        // ⚠️ **`mode=add` の衝突を本物どおりに返す**。以前は常に上書きしていたため、
        // バックアップの「409 → 同一性確認 → autorename で再試行」という現実の経路を
        // 一度も通せなかった（別名保存された写真の**実際の保存先**を台帳が持てているか、
        // という検証がまるごと抜けていた）。
        if arg.mode == "add", let existing = files[key], existing.contentHash != hash {
            guard arg.autorename == true else {
                return resp(409, #"{"error_summary":"path/conflict/file/.."}"#)
            }
            key = Self.autorenamed(key, existing: Set(files.keys)).lowercased()
        }
        bodies[key] = body
        files[key] = Entry(contentHash: hash, isFolder: false, rev: "r\(files.count)",
                           displayName: (arg.path as NSString).lastPathComponent,
                           size: body.count)
        note(key, deleted: false)
        return resp(200, #"{"path_lower":"\#(key)","content_hash":"\#(hash)"}"#)
    }

    private func handleDownload(_ request: URLRequest, _ resp: (Int, String) -> (Data, URLResponse))
        -> (Data, URLResponse) {
        struct Arg: Decodable { let path: String }
        guard let header = request.value(forHTTPHeaderField: "Dropbox-API-Arg"),
              let arg = try? JSONDecoder().decode(Arg.self, from: Data(header.utf8)),
              files[arg.path.lowercased()] != nil else {
            return resp(409, #"{"error_summary":"path/not_found/"}"#)
        }
        // アップロードされた本体があればそれを返す（seed したファイルは中身を持たない）。
        guard let body = bodies[arg.path.lowercased()] else { return resp(200, "{}") }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!)
    }

    /// Dropbox の autorename 相当（"a.jpg" → "a (1).jpg"）。
    private static func autorenamed(_ path: String, existing: Set<String>) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for n in 1...999 {
            let candidate = ext.isEmpty ? "\(dir)/\(stem) (\(n))" : "\(dir)/\(stem) (\(n)).\(ext)"
            if !existing.contains(candidate) { return candidate }
        }
        return path
    }
}

/// 常に同じトークンを返す（偽サーバーは検証しない）。
public final class FakeTokenProvider: AccessTokenProvider, @unchecked Sendable {
    public init() {}
    public func freshAccessToken() async throws -> String { "test-token" }
}
