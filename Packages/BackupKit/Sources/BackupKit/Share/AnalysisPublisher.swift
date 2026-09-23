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
            acknowledgedDeviceFolder: defaults.string(forKey: ShareSettingsKeys.acknowledgedAnalysisOwner))
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
        let window = AnalysisPublishPlanning.window(
            presentShards: Set(refKeysByShard.keys),
            publishedDigests: publishedDigests(),
            cursor: defaults.integer(forKey: ShareSettingsKeys.publishAnalysisCursor),
            budget: budget)
        Diagnostics.mark("share.publishAnalysis: 開始（写真 \(photos.count) 枚・"
                         + "この回に見るシャード \(window.shards.count)/\(refKeysByShard.count)）")

        let root = BackupLayout.analysisRoot(root: backupRoot,
                                             deviceFolder: BackupDeviceIdentity.currentFolderName())
        var digests = publishedDigests()
        var uploaded = 0
        var publishedPhotos = 0
        for shard in window.shards {
            guard let refKeys = refKeysByShard[shard] else { continue }
            // このシャードの写真ぶんだけ解析を取る（数百枚）。取れた中身は次の shard へ持ち越さない。
            let result = await source.analysisEntries(forRefKeys: refKeys)
            var entries: [String: ShareAnalysisData.Entry] = [:]
            for (refKey, entry) in result.entries {
                guard let hash = hashByRefKey[refKey] else { continue }
                entries[hash] = entry
            }
            // まだ 1 枚も解析されていないシャードは置かない（空のファイルを作らない）。
            guard !entries.isEmpty else { continue }
            publishedPhotos += entries.count
            let file = ShareAnalysisData.File(versions: result.versions, entries: entries)
            guard let data = AnalysisPublishPlanning.encoded(file) else { continue }
            let digest = AnalysisPublishPlanning.fingerprint(data)
            guard digests[shard] != digest else { continue }   // 変わっていないシャードは上げない
            let path = ShareAnalysisData.shardPath(setFolderPath: root, shard: shard)
            guard await copier.uploadFile(data: data, to: path, token: token) else { break }
            digests[shard] = digest
            uploaded += 1
        }
        // 対象から消えたシャード（写真が Dropbox から消えた等）は消す。記録も落とす。
        if !window.stale.isEmpty {
            let paths = window.stale.map { "\(root)/\(ShareAnalysisData.subfolderName)/\($0)" }
            _ = await copier.deleteBatch(paths: paths, token: token)
            for name in window.stale {
                let shard = name.dropFirst(ShareAnalysisData.shardFilePrefix.count).dropLast(5)
                digests[String(shard)] = nil
            }
        }
        setPublishedDigests(digests)
        defaults.set(window.nextCursor, forKey: ShareSettingsKeys.publishAnalysisCursor)
        // 変更が無い回も名乗りは更新する（「この端末は生きている」を残す＝引き継ぎの判断材料）。
        await writeOwner(copier: copier, path: ownerPath, previous: remoteOwner,
                         photoCount: photos.count, token: token)
        let message = uploaded == 0 && window.stale.isEmpty
            ? "変更なし（見たシャード \(window.shards.count)・写真 \(publishedPhotos)）"
            : "上げた \(uploaded)/\(window.shards.count) シャード"
                + "（見ていないシャード \(window.remaining)・消した \(window.stale.count)"
                + "・写真 \(publishedPhotos)）"
        Diagnostics.mark("share.publishAnalysis: " + message)
        return Outcome(uploaded: uploaded, remaining: window.remaining, message: message)
    }

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
                            token: String) async {
        let owner = AnalysisOwnership.claim(
            myDeviceFolder: BackupDeviceIdentity.currentFolderName(),
            myDeviceName: BackupDeviceIdentity.currentDisplayName(),
            previous: previous, now: Date(), photoCount: photoCount)
        guard let data = AnalysisOwnership.encode(owner) else { return }
        _ = await copier.uploadFile(data: data, to: path, token: token)
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
