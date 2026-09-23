import DropboxCore
import Foundation

/// 受信側: 家族の共有フォルダから解析データを見つけて取得する（ADR-112）。
/// rev（Dropbox のファイル版）を記録し、**変わったものだけ**ダウンロード・検証して返す。
/// ストアへの取り込み（TagStore / 埋め込み / 顔）はアプリ側（Composition Root）が行う。
public struct ShareAnalysisFetch {
    private let httpClient: HTTPClient

    /// 記録の置き場所（rev・続きの印・受信能力の版・保存失敗の数）。
    ///
    /// ⚠️ **インスタンスに持たせる**（レビュー 6 周目）。5 周目では
    /// `nonisolated(unsafe) static var` にしたが、それは競合を**直さず移しただけ**だった
    /// ——並行して走る 2 つのテストスイートが 1 つのグローバルを取り合い、
    /// 片方の `pruneStoredRevs` がもう片方の rev を消す競合がそのまま再現した
    /// （しかも後始末が「元の値」でなく `.standard` に戻すので、既定の置き場所を汚した）。
    /// 可変なグローバルを差し込み口にしてはいけない。
    private let defaults: UserDefaults

    public init(httpClient: HTTPClient = URLSessionHTTPClient(),
                defaults: UserDefaults = .standard) {
        self.httpClient = httpClient
        self.defaults = defaults
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

    /// 連続でダウンロードに失敗したら、その回は畳む（レート制限・圏外で叩き続けない）。
    static let failureStreakLimit = 5

    /// 前回どこまで取ったか（次はその続きから）。
    ///
    /// ⚠️ **打ち切りだけでは進まない**（レビュー指摘）。候補から外れるのは
    /// 「取り込み済み」として rev を記録できたときだけで、その条件は何度も続けて
    /// 満たされないことがある（受信側の同期が途中だとシャードはほぼ全部が未突合）。
    /// 毎回先頭 48 個を取り直すと、**49 個目以降は一度もダウンロードされない**
    /// ——打ち切りを入れる前は全部取れていたので、これは打ち切りが作った飢餓。
    /// 続きから始めて一巡させれば、記録できない回が続いても全部が順番に回る。
    private static let cursorKey = "share.analysisFetchCursor"

    func storedCursor() -> String? {
        defaults.string(forKey: Self.cursorKey)
    }

    /// 撮影日の保存に失敗し続けたときに、取り込みを止め続けないための上限（レビュー指摘）。
    ///
    /// ⚠️ 保存失敗で「取り込み済み」を見送るのは、やり直す価値があるから。ただし容量不足など
    /// **直らない失敗**だと毎回見送られ、解析データの取り込みが一度も記録されないまま
    /// 毎回 48 個を取り直し続ける。撮影日は並び順のための付加情報で、タグ・埋め込み・顔の
    /// 取り込み自体は成功している——数回でこらえて先へ進める。
    public static let captureDateSaveRetryLimit = 3

    private static let saveFailureKey = "share.captureDateSaveFailures"

    /// 撮影日の保存失敗を数える。まだ見送ってよいなら true。
    public func shouldRetryCaptureDateSave() -> Bool {
        let defaults = defaults
        let count = defaults.integer(forKey: Self.saveFailureKey) + 1
        defaults.set(count, forKey: Self.saveFailureKey)
        if count > Self.captureDateSaveRetryLimit {
            BackupLogger.error("ShareAnalysisFetch: capture-date save has failed \(count) times — "
                + "marking analysis imported anyway (ordering will stay wrong)")
            return false
        }
        return true
    }

    /// 保存できた回に数え直す。
    public func resetCaptureDateSaveFailures() {
        defaults.removeObject(forKey: Self.saveFailureKey)
    }

    func saveCursor(_ path: String?) {
        if let path { defaults.set(path, forKey: Self.cursorKey) }
        else { defaults.removeObject(forKey: Self.cursorKey) }
    }

    /// 1 回の実行で「どれを試すか」を決める（純ロジック・テスト対象）。
    ///
    /// 実際のダウンロードの成否は呼び出し側が知っているので、ここでは
    /// **成否に応じて印と予算がどう動くか**を 1 か所に固めてテストできる形にする。
    /// 規則は `fetchUpdated` の中のコメントに書いた 2 つ:
    /// - 印は**試した**ところまで進む（先頭が恒久的に失敗しても止まらない）
    /// - 予算は**取れた数**で数える（1 件も取れない回に印だけ進めない）
    struct RunPlan: Equatable {
        /// 試した順のパス。
        var attempted: [String] = []
        /// 次に保存する印（試したものが無ければ nil＝据え置き）。
        var cursor: String?
    }

    /// `outcome` は 1 件ごとの結果（true＝取れた）。テストから成否を並べて渡す。
    static func planRun(rotated: [String], budget: Int, failureStreakLimit: Int,
                        outcome: (String) -> Bool) -> RunPlan {
        var plan = RunPlan()
        var taken = 0
        var streak = 0
        for path in rotated {
            if taken >= budget { break }
            if streak >= failureStreakLimit { break }
            plan.attempted.append(path)
            plan.cursor = path
            if outcome(path) { taken += 1; streak = 0 } else { streak += 1 }
        }
        return plan
    }

    /// 候補を「前回の続き」から並べ替える（純ロジック・テスト対象）。
    /// `cursor` より大きい最初の要素から始めて、末尾まで行ったら先頭へ回り込む。
    static func rotated(_ candidates: [String], after cursor: String?) -> [String] {
        guard let cursor, !candidates.isEmpty else { return candidates }
        guard let start = candidates.firstIndex(where: { $0 > cursor }) else { return candidates }
        return Array(candidates[start...] + candidates[..<start])
    }

    /// 受信側の読み取り能力が上がっていたら、記録済み rev を 1 回だけ捨てる。
    func invalidateRevsIfCapabilityGrew() {
        let defaults = defaults
        let stored = defaults.integer(forKey: Self.capabilityVersionKey)   // 未設定は 0
        guard stored < Self.receiverCapabilityVersion else { return }
        defaults.removeObject(forKey: ShareSettingsKeys.importedAnalysisRevs)
        defaults.set(Self.receiverCapabilityVersion, forKey: Self.capabilityVersionKey)
        BackupLogger.info("ShareAnalysisFetch: receiver capability \(stored) → "
            + "\(Self.receiverCapabilityVersion) — re-fetching all analysis data once")
    }

    /// **同じ Dropbox に接続している他の端末の解析フォルダ**を見つける（ADR-222）。
    ///
    /// 置き場所は `<root>/<端末>/Analysis`。ルート直下の端末フォルダを 1 回、その下を端末ごとに
    /// 1 回だけ一覧する（`Analysis` の中身は `fetchUpdated` が再帰で見る）。
    /// ⚠️ **自分の端末フォルダは除く**（自分が書いたものを取り込み直さない）。
    /// ⚠️ バックアップのルートを再帰で一覧しない——写真が数万枚あるので一覧だけで重い。
    public func accountAnalysisRoots(backupRoot: String, ownDeviceFolder: String,
                                     token: String) async -> [String] {
        let copier = DropboxShareCopier(httpClient: httpClient)
        guard let devices = await copier.listFolder(path: backupRoot, token: token) else { return [] }
        var roots: [String] = []
        for device in devices where device.isFolder {
            guard device.name.lowercased() != ownDeviceFolder.lowercased() else { continue }
            guard let children = await copier.listFolder(path: device.pathLower, token: token)
            else { continue }
            if let analysis = children.first(where: {
                $0.isFolder && $0.name.lowercased() == BackupLayout.analysisSubfolder.lowercased()
            }) {
                roots.append(analysis.pathLower)
            }
        }
        return roots
    }

    public func fetchUpdated(roots: [String], token: String) async -> [Fetched] {
        invalidateRevsIfCapabilityGrew()
        let copier = DropboxShareCopier(httpClient: httpClient)
        let knownRevs = storedRevs()
        var out: [Fetched] = []
        var seenPaths = Set<String>()
        var allListed = true

        // 1 巡目: 一覧を全部見て、候補（rev が変わったもの）を集める。
        // ⚠️ 一覧には**必ず**入れる（打ち切っても記録の掃除が狂わないように）。
        var candidates: [(path: String, rev: String, setFolder: String)] = []
        for root in roots {
            guard let listing = await copier.listFolder(path: root, token: token, recursive: true) else {
                allListed = false   // 一覧が取れない回は記録を捨てない（全部の再取得を誘発する）
                // ⚠️ **黙って諦めない**（diagnostics-82）。家族フォルダが消えていると
                // 取り込みは永久に 0 件だが、ログが 1 行も出ないので実機で気づけなかった。
                BackupLogger.error("ShareAnalysisFetch: cannot list family folder — \(root) "
                    + "(deleted, renamed, or no longer shared?)")
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
        //
        // ## 印（続きの位置）と予算の規則 — **一度ひっくり返して戻した。読まずに変えないこと。**
        //
        // 規則1: **印は「試した」ところまで進める**（成否を問わない）。
        // 規則2: **予算は「取れた数」で数える**。
        //
        // この 2 つは別々の目的を持っていて、混ぜると必ずどちらかが壊れる。
        // - 規則1 を破り「取れたところまで」にすると、**先頭の候補が恒久的に失敗したときに
        //   印が一生進まない**（消えた共有フォルダ・権限剥奪・窓が閉じて 1 件目から取り消し）。
        //   その先の候補は二度とダウンロードされず、取り込みが丸ごと止まる。しかも
        //   「1 件でも取れれば印はそこまで進む」ので、守りたかった性質（失敗を飛ばさない）すら
        //   成立していなかった。これはレビュー 5 周目で見つかった。
        // - 規則2 を破り「試した数」で数えると、レート制限や通信断で 1 件も取れなかった回に
        //   印だけ 48 個進み、その 48 個が一巡するまで戻ってこない。これは 4 周目で見つかった。
        //
        // 規則1 の代償は「失敗したシャードは一巡ぶん遅れる」こと。候補は ⌈N/48⌉ 回で一周するので
        // 遅れは有界で、**止まらない**。止まる方の害が桁違いに大きいので、こちらを選ぶ。
        // 連続で落ち続けたらその回は畳む（レート制限・圏外で 48 回叩かない）。
        let order = Dictionary(candidates.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let rotatedPaths = Self.rotated(candidates.map(\.path).sorted(), after: storedCursor())
        var lastAttempted: String?
        var taken = 0
        var consecutiveFailures = 0
        for path in rotatedPaths {
            if taken >= Self.maxFilesPerRun { break }
            if Task.isCancelled { break }
            if consecutiveFailures >= Self.failureStreakLimit {
                BackupLogger.info("ShareAnalysisFetch: giving up this run after "
                    + "\(consecutiveFailures) consecutive download failures")
                break
            }
            guard let candidate = order[path] else { continue }
            lastAttempted = path                               // 規則1
            guard let data = await copier.downloadFile(path: path, token: token) else {
                BackupLogger.error("ShareAnalysisFetch: download failed — \(path)")
                consecutiveFailures += 1                       // 規則2: 予算は減らさない
                continue
            }
            consecutiveFailures = 0
            taken += 1
            guard let decoded = ShareAnalysisData.decodeValidated(data) else {
                BackupLogger.error("ShareAnalysisFetch: invalid analysis data — \(path)")
                continue
            }
            out.append(Fetched(analysisPathLower: path, rev: candidate.rev,
                               file: decoded, setFolderPathLower: candidate.setFolder))
        }
        if let lastAttempted { saveCursor(lastAttempted) }
        // 一覧に無くなったパスの rev 記録は捨てる（肥大防止。以前の「500 件超で末尾 300 件」は
        // シャード化で件数が増えると取り込み済みの記録まで捨てて再取得を誘発する）。
        if allListed { pruneStoredRevs(keeping: seenPaths) }
        return out
    }

    /// 取り込み完了を記録する（同じ rev の再取り込みを省く）。
    public func markImported(_ fetched: Fetched) {
        guard !fetched.rev.isEmpty else { return }
        var revs = storedRevs()
        revs[fetched.analysisPathLower] = fetched.rev
        save(revs)
    }

    /// 一覧に無くなったパスの記録を捨てる（家族フォルダの整理・シャードの消滅）。
    func pruneStoredRevs(keeping paths: Set<String>) {
        let revs = storedRevs()
        let kept = revs.filter { paths.contains($0.key) }
        if kept.count != revs.count { save(kept) }
    }

    private func save(_ revs: [String: String]) {
        if let data = try? JSONEncoder().encode(revs) {
            defaults.set(data, forKey: ShareSettingsKeys.importedAnalysisRevs)
        }
    }

    func storedRevs() -> [String: String] {
        guard let data = defaults.data(forKey: ShareSettingsKeys.importedAnalysisRevs),
              let revs = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return revs
    }
}
