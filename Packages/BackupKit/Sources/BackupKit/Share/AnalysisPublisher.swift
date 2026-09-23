import DropboxCore
import Foundation
import MosaicSupport

/// **クラウドの写真の解析結果を、同じ Dropbox に接続している人へ公開する**（ADR-222）。
///
/// ## なぜ要るか
/// Dropbox に家族を接続すると、写真そのものは接続した時点で相手からも見える。ところが
/// 解析（タグ・CLIP 埋め込み・顔・人物名・撮影日）は端末の中にしか無いので、家族の端末は
/// 同じ写真をもう一度ダウンロードして解析し直していた（6.8 万枚で数時間 × 人数）。しかも
/// 人物名は引き継がれない。共有セット（`Share/`）の解析データは**写真のコピーと対**なので、
/// 既にクラウドにある写真には使えない（コピーを作る意味が無い）。
///
/// ## 置き場所と形式
/// `<root>/<端末>/Analysis/.mosaic-share/shard-xx.json`。中身は共有セットと**同じ形式**
/// （`ShareAnalysisData`・鍵は Dropbox の `content_hash`）なので、受信側の取得・検証・取り込みは
/// そのまま使える。端末ごとに別フォルダなので、家族が同じ Dropbox でも互いを上書きしない。
///
/// ## 上げ方
/// 写真 1 枚あたり 1〜2KB（CLIP 埋め込みが主）で、6.8 万枚なら 100〜200MB になる。
/// **変わったシャードだけ**を、1 回につき `budget` 個まで上げる（`AnalysisPublishPlanning`）。
/// 呼び出し側は背景の処理枠（`BackgroundYield` の `.cloudTrickle`）の中で回す。
public final class AnalysisPublisher {

    /// 1 回ぶんの結果。`blockedBy` が付いていたら、**別の端末が公開している**（止めた）。
    public struct Outcome: Sendable {
        public var uploaded = 0
        public var remaining = 0
        public var blockedBy: AnalysisOwnership.Owner?
        public var message = ""
    }

    /// クラウド写真 1 枚（公開対象）。
    public struct CloudPhoto: Sendable, Equatable {
        public let refKey: String
        public let contentHash: String
        public init(refKey: String, contentHash: String) {
            self.refKey = refKey
            self.contentHash = contentHash
        }
    }

    private let tokenProvider: AccessTokenProvider
    private let httpClient: HTTPClient
    private let defaults: UserDefaults
    /// 解析結果の供給元（アプリの Composition Root が実装）。
    private weak var analysisSource: ShareAnalysisSource?

    public init(tokenProvider: AccessTokenProvider,
                analysisSource: ShareAnalysisSource?,
                httpClient: HTTPClient = URLSessionHTTPClient(),
                defaults: UserDefaults = .standard) {
        self.tokenProvider = tokenProvider
        self.analysisSource = analysisSource
        self.httpClient = httpClient
        self.defaults = defaults
    }

    /// 1 回ぶん公開する。
    /// - Parameter photos: 解析済みか判断せずに渡してよい（解析が無い写真はエントリにならない）。
    /// - Returns: 上げたシャード数と、まだ残っている数。
    ///
    /// ⚠️ **抜けるときも必ず 1 行残す**（実機ログ diagnostics-83）。黙って return していたため、
    /// ログを見ても「順番が回ってこなかった」のか「回ってきたが早々に抜けた」のか区別できず、
    /// 原因（手順の最後に置いたので窓が先に切れていた）に辿り着くのに実機ログ 1 本ぶん遠回りした。
    @discardableResult
    public func publish(photos: [CloudPhoto],
                        budget: Int = AnalysisPublishPlanning.defaultBudget) async -> Outcome {
        guard ShareSettingsKeys.isPublishAnalysisEnabled(defaults) else {
            return bail("設定がオフ")
        }
        guard !photos.isEmpty else { return bail("クラウド写真が 0 件") }
        guard let source = analysisSource else { return bail("解析の供給元が無い") }
        guard let token = try? await tokenProvider.freshAccessToken() else {
            return bail("トークンが取れない")
        }

        // ⚠️ **公開するのは 1 台だけ**（ADR-222 追補）。端末フォルダは分かれているので
        // ファイルは壊れないが、2 台で公開すると同じ解析が台数ぶん Dropbox に積まれる。
        // 止めるのではなく知らせる——利用者が設定で「この端末で公開する」を選べば引き継げる
        // （端末を失くしたら、そうでないと永久に公開が止まる）。
        let copier = DropboxShareCopier(httpClient: httpClient)
        let ownerPath = BackupLayout.analysisOwnerPath(root: backupRoot)
        let remoteOwner = await copier.downloadFile(path: ownerPath, token: token)
            .flatMap(AnalysisOwnership.decode)
        let decision = AnalysisOwnership.decide(
            remote: remoteOwner, myDeviceFolder: BackupDeviceIdentity.currentFolderName(),
            myDeviceID: BackupDeviceIdentity.currentID(),
            acknowledgedDeviceFolder: defaults.string(forKey: ShareSettingsKeys.acknowledgedAnalysisOwner))
        // ⚠️ **承諾は引き継いだ時点で役目を終える**（レビュー指摘）。残したままだと、相手が
        // あとでまた名乗っても黙って公開を続ける（2 台とも「引き継いだ」状態になり得る）。
        if case .ours = decision { defaults.removeObject(forKey: ShareSettingsKeys.acknowledgedAnalysisOwner) }
        guard AnalysisOwnership.allowsPublishing(decision) else {
            guard case .otherDevice(let owner) = decision else { return bail("公開できない") }
            var outcome = bail("別の端末（\(owner.deviceFolder)）が公開している — 設定で確認して下さい")
            outcome.blockedBy = owner
            return outcome
        }
        // ⚠️ **この回に見るシャードぶんだけ**を組み立てる（実機ログ diagnostics-85）。
        // 全シャードを一度に作って全部を JSON にしていた頃はフットプリントが 637MB まで上がり、
        // 解析の取得も 9.7 万枚ぶん（2,000 枚 × 49 回）で 1 回 67 秒かかっていた。
        // 写真をシャード（content_hash の先頭 2 桁）で束ね、窓の shard だけを取りに行く。
        var refKeysByShard: [String: [String]] = [:]
        var hashByRefKey: [String: String] = [:]
        for photo in photos {
            let hash = photo.contentHash.lowercased()
            refKeysByShard[ShareAnalysisData.shardName(forHash: hash), default: []].append(photo.refKey)
            hashByRefKey[photo.refKey] = hash
        }
        let allShards = refKeysByShard.keys.sorted()
        let window = AnalysisPublishPlanning.window(
            presentShards: Set(refKeysByShard.keys),
            publishedDigests: publishedDigests(),
            cursor: defaults.integer(forKey: ShareSettingsKeys.publishAnalysisCursor),
            budget: budget)
        Diagnostics.mark("share.publishAnalysis: 開始（写真 \(photos.count) 枚・"
                         + "この回に見るシャード \(window.shards.count)/\(refKeysByShard.count)）")

        // ⚠️ **名乗りは先に書く**（実機ログ diagnostics-91）。以前は最後に書いていたので、
        // 窓が切れる間際に公開した回は名乗りの書き込みごと落ちていた（`upload failed` が
        // シャードと名乗りで並んでいた）。名乗りが無いままだと、次の端末は「誰も名乗って
        // いない」と見て**二重に公開を始める**——この仕組みが防ぎたかったことそのもの。
        // まだ自分のものでないときだけ先に書く（自分のものなら最後の更新で足りる）。
        if case .ours = decision {} else {
            await writeOwner(copier: copier, path: ownerPath, previous: remoteOwner,
                             photoCount: photos.count, token: token, published: false)
        }

        let root = BackupLayout.analysisRoot(root: backupRoot,
                                             deviceFolder: BackupDeviceIdentity.currentFolderName())
        var digests = publishedDigests()
        var uploaded = 0
        var publishedPhotos = 0
        // ⚠️ **上げ損ねたシャードを飛ばさない**（実機ログ diagnostics-86）。
        // 回線が切れて 1 個失敗したとき、印（cursor）を窓の最後まで進めてしまうと、その shard は
        // **一巡（32 窓＝半日）待たされる**。どこまで済んだかで印を決め、失敗したら次回そこから。
        var lastDone: String?
        var failed: String?
        for shard in window.shards {
            guard let refKeys = refKeysByShard[shard] else { lastDone = shard; continue }
            // このシャードの写真ぶんだけ解析を取る（数百枚）。取れた中身は次の shard へ持ち越さない。
            let result = await source.analysisEntries(forRefKeys: refKeys)
            // ⚠️ **同じ content_hash に複数の refKey が当たる**（原本・バックアップのコピー・
            // 共有のコピーは中身が同じ）。`result.entries` は辞書なので反復順が毎回変わり、
            // 勝つ refKey が変わると**中身が変わっていないのに指紋が変わる**＝毎回上げ直す。
            // refKey の小さい方を決定的に選ぶ（レビュー指摘）。
            var entries: [String: ShareAnalysisData.Entry] = [:]
            var winnerRefKey: [String: String] = [:]
            for (refKey, entry) in result.entries {
                guard let hash = hashByRefKey[refKey] else { continue }
                if let current = winnerRefKey[hash], current <= refKey { continue }
                winnerRefKey[hash] = refKey
                entries[hash] = entry
            }
            // まだ 1 枚も解析されていないシャードは置かない（空のファイルを作らない）。
            guard !entries.isEmpty else { lastDone = shard; continue }
            publishedPhotos += entries.count
            let file = ShareAnalysisData.File(versions: result.versions, entries: entries)
            guard let data = AnalysisPublishPlanning.encoded(file) else { lastDone = shard; continue }
            let digest = AnalysisPublishPlanning.fingerprint(data)
            guard digests[shard] != digest else { lastDone = shard; continue }   // 変わっていなければ上げない
            let path = ShareAnalysisData.shardPath(setFolderPath: root, shard: shard)
            guard await copier.uploadFile(data: data, to: path, token: token) else {
                // 回線が切れた・レート制限。残りも失敗する見込みなので畳むが、印は進めない。
                failed = shard
                break
            }
            digests[shard] = digest
            lastDone = shard
            uploaded += 1
            clearFailureStreak()
        }
        // 対象から消えたシャード（写真が Dropbox から消えた等）は消す。記録も落とす。
        if !window.stale.isEmpty {
            let paths = window.stale.map { "\(root)/\(ShareAnalysisData.subfolderName)/\($0)" }
            // ⚠️ **消せたときだけ記録を落とす**（レビュー指摘）。失敗しても記録を消すと、
            // そのシャードは二度と `stale` に挙がらない（stale は記録から作る）ので、
            // **孤児のシャードが Dropbox に残り続ける**——受信側は消えた写真の解析を取り込み続ける。
            if await copier.deleteBatch(paths: paths, token: token) {
                for name in window.stale {
                    let shard = name.dropFirst(ShareAnalysisData.shardFilePrefix.count).dropLast(5)
                    digests[String(shard)] = nil
                }
            } else {
                Diagnostics.mark("share.publishAnalysis: 消せなかった \(window.stale.count) 個は"
                                 + "記録に残す（次回また消しにいく）")
            }
        }
        setPublishedDigests(digests)
        // 済んだところまでで印を決める（失敗した shard は次回そこから）。
        // ⚠️ ただし**同じ shard で続けて失敗したら飛ばす**（レビュー指摘）。直らない失敗
        // （容量超過 507・権限 401・特定パスの恒久エラー）だと、印が固まって
        // **01〜ff が一度も公開されない**。受信側は同じ飢餓を踏んで「印は試したところまで
        // 進める」と決めている（`ShareAnalysisFetch` の規則1）ので、こちらも歯止めを持つ。
        let skipStuck = failed != nil && bumpFailureStreak(for: failed!) >= Self.failureStreakLimit
        if skipStuck {
            Diagnostics.mark("share.publishAnalysis: \(failed!) が \(Self.failureStreakLimit) 回続けて"
                             + "失敗 — 今回は飛ばして次へ進む")
        }
        defaults.set(cursorAfter(lastDone: skipStuck ? failed : lastDone, shards: allShards),
                     forKey: ShareSettingsKeys.publishAnalysisCursor)
        // 変更が無い回も名乗りは更新する（「この端末は生きている」を残す＝引き継ぎの判断材料）。
        await writeOwner(copier: copier, path: ownerPath, previous: remoteOwner,
                         photoCount: photos.count, token: token, published: uploaded > 0)
        let failure = failed.map { "・\($0) で失敗したので次回はそこから" } ?? ""
        let message = uploaded == 0 && window.stale.isEmpty && failed == nil
            ? "変更なし（見たシャード \(window.shards.count)・写真 \(publishedPhotos)）"
            : "上げた \(uploaded)/\(window.shards.count) シャード"
                + "（見ていないシャード \(window.remaining)・消した \(window.stale.count)"
                + "・写真 \(publishedPhotos)\(failure)）"
        Diagnostics.mark("share.publishAnalysis: " + message)
        return Outcome(uploaded: uploaded, remaining: window.remaining, message: message)
    }

    /// 次回の再開位置。**済んだところまで**で決める（失敗した shard は次回そこから引き直す）。
    /// 1 個も済んでいなければ印は据え置き（同じ窓をもう一度）。
    private func cursorAfter(lastDone: String?, shards: [String]) -> Int {
        guard let lastDone, let index = shards.firstIndex(of: lastDone) else {
            return defaults.integer(forKey: ShareSettingsKeys.publishAnalysisCursor)
        }
        return shards.isEmpty ? 0 : (index + 1) % shards.count
    }

    /// 同じシャードで続けて失敗したら飛ばす回数。
    static let failureStreakLimit = 3
    private static let failureStreakKey = "sharePublishAnalysisFailureStreak"

    /// 失敗の連続回数を数える（別のシャードで失敗したら数え直す）。
    private func bumpFailureStreak(for shard: String) -> Int {
        let stored = defaults.string(forKey: Self.failureStreakKey)?.split(separator: "|")
        let count = (stored?.first).map(String.init) == shard
            ? (stored?.last).flatMap { Int($0) } ?? 0
            : 0
        let next = count + 1
        defaults.set("\(shard)|\(next)", forKey: Self.failureStreakKey)
        return next
    }

    private func clearFailureStreak() { defaults.removeObject(forKey: Self.failureStreakKey) }

    /// 設定のバックアップルート。
    private var backupRoot: String {
        defaults.string(forKey: BackupSettingsKeys.dropboxFolder)
            ?? BackupSettingsKeys.defaultDropboxFolder
    }

    /// 何もせず抜けるときの共通処理。**理由は必ずログに残す**（実機ログ diagnostics-83/84）。
    private func bail(_ reason: String) -> Outcome {
        Diagnostics.mark("share.publishAnalysis: \(reason)")
        return Outcome(message: reason)
    }

    /// 名乗りを書く（引き継いだ場合もここで自分になる）。失敗しても公開自体は成功扱い
    /// ——名乗りは助言であって、公開の正しさには関わらない。
    private func writeOwner(copier: DropboxShareCopier, path: String,
                            previous: AnalysisOwnership.Owner?, photoCount: Int,
                            token: String, published: Bool) async {
        let owner = AnalysisOwnership.claim(
            myDeviceFolder: BackupDeviceIdentity.currentFolderName(),
            myDeviceID: BackupDeviceIdentity.currentID(),
            myDeviceName: BackupDeviceIdentity.currentDisplayName(),
            previous: previous, now: Date(), photoCount: photoCount, published: published)
        guard let data = AnalysisOwnership.encode(owner) else { return }
        // ⚠️ 失敗は**必ず残す**。名乗りが書けていないと、次の端末が二重に公開を始める。
        // ただし窓の期限切れ（キャンセル）は毎回起きる正常な終わり方なので、同じ文言で騒がない
        // ——本当に危ない回の信号が埋もれる（レビュー指摘）。
        if await copier.uploadFile(data: data, to: path, token: token) == false {
            Diagnostics.mark(Task.isCancelled
                             ? "share.publishAnalysis: 窓が切れて名乗りを書けなかった（次の窓で書く）"
                             : "share.publishAnalysis: 名乗りを書けなかった — 次の端末が二重に公開し得る")
        }
    }

    /// 今の名乗りを読む（設定画面の注意書き用）。
    public func currentOwner() async -> AnalysisOwnership.Owner? {
        guard let token = try? await tokenProvider.freshAccessToken() else { return nil }
        let copier = DropboxShareCopier(httpClient: httpClient)
        return await copier.downloadFile(path: BackupLayout.analysisOwnerPath(root: backupRoot),
                                         token: token).flatMap(AnalysisOwnership.decode)
    }


    private func publishedDigests() -> [String: String] {
        guard let data = defaults.data(forKey: ShareSettingsKeys.publishedAnalysisDigests),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    private func setPublishedDigests(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: ShareSettingsKeys.publishedAnalysisDigests)
    }
}
