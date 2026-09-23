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
                        budget: Int = AnalysisPublishPlanning.defaultBudget) async
        -> (uploaded: Int, remaining: Int) {
        guard ShareSettingsKeys.isPublishAnalysisEnabled(defaults) else {
            Diagnostics.mark("share.publishAnalysis: 設定がオフ — 何もしない")
            return (0, 0)
        }
        guard !photos.isEmpty else {
            Diagnostics.mark("share.publishAnalysis: クラウド写真が 0 件 — 何もしない")
            return (0, 0)
        }
        guard let source = analysisSource else {
            Diagnostics.mark("share.publishAnalysis: 解析の供給元が無い — 何もしない")
            return (0, 0)
        }
        guard let token = try? await tokenProvider.freshAccessToken() else {
            Diagnostics.mark("share.publishAnalysis: トークンが取れない — 何もしない")
            return (0, 0)
        }
        Diagnostics.mark("share.publishAnalysis: 開始（写真 \(photos.count) 枚）")

        // 解析結果を集める。⚠️ 6.8 万枚を一度に渡さない（base64 の文字列が一斉に載る）。
        let byRefKey = Dictionary(photos.map { ($0.refKey, $0.contentHash) },
                                  uniquingKeysWith: { a, _ in a })
        var entries: [String: ShareAnalysisData.Entry] = [:]
        var versions = ShareAnalysisData.Versions(tag: 0, perception: 0, face: 0)
        for chunk in stride(from: 0, to: photos.count, by: Self.entryChunkSize).map({
            Array(photos[$0..<min($0 + Self.entryChunkSize, photos.count)])
        }) {
            let result = await source.analysisEntries(forRefKeys: chunk.map(\.refKey))
            versions = result.versions
            for (refKey, entry) in result.entries {
                guard let hash = byRefKey[refKey] else { continue }
                entries[hash.lowercased()] = entry
            }
        }

        let files = ShareAnalysisData.shards(versions: versions, entries: entries)
        let plan = AnalysisPublishPlanning.plan(files: files,
                                                publishedDigests: publishedDigests(),
                                                cursor: defaults.integer(forKey: ShareSettingsKeys.publishAnalysisCursor),
                                                budget: budget)
        guard !plan.uploads.isEmpty || !plan.stale.isEmpty else {
            Diagnostics.mark("share.publishAnalysis: 変更なし（写真 \(photos.count)・シャード \(files.count)）")
            return (0, 0)
        }

        let root = BackupLayout.analysisRoot(
            root: defaults.string(forKey: BackupSettingsKeys.dropboxFolder)
                ?? BackupSettingsKeys.defaultDropboxFolder,
            deviceFolder: BackupDeviceIdentity.currentFolderName())
        let copier = DropboxShareCopier(httpClient: httpClient)
        var digests = publishedDigests()
        var uploaded = 0
        for upload in plan.uploads {
            let path = ShareAnalysisData.shardPath(setFolderPath: root, shard: upload.shard)
            guard await copier.uploadFile(data: upload.data, to: path, token: token) else { break }
            digests[upload.shard] = upload.digest
            uploaded += 1
        }
        // 対象から消えたシャード（写真が Dropbox から消えた等）は消す。記録も落とす。
        if !plan.stale.isEmpty {
            let paths = plan.stale.map { "\(root)/\(ShareAnalysisData.subfolderName)/\($0)" }
            _ = await copier.deleteBatch(paths: paths, token: token)
            for name in plan.stale {
                let shard = name.dropFirst(ShareAnalysisData.shardFilePrefix.count).dropLast(5)
                digests[String(shard)] = nil
            }
        }
        setPublishedDigests(digests)
        defaults.set(plan.nextCursor, forKey: ShareSettingsKeys.publishAnalysisCursor)
        Diagnostics.mark("share.publishAnalysis: 上げた \(uploaded)/\(plan.uploads.count) シャード"
                         + "（残り \(plan.remaining)・消した \(plan.stale.count)・写真 \(entries.count)）")
        return (uploaded, plan.remaining)
    }

    /// 1 回に解析結果を問い合わせる写真の数（base64 の一時文字列を抱え込まないため）。
    static let entryChunkSize = 2_000

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
