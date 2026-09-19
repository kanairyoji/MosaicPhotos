import AutoAlbumCore
import DropboxKit
import MosaicSupport
import PhotosFeatureKit
import SwiftUI

/// 「AI 解析の状況」画面が表示する数字と、その**数え直しループの持ち主**（ADR-196）。
///
/// ## なぜビューから出したか
/// `AIAnalysisStatusView.body` は `Group { 7 つの Section }` なので、`.task` / `.onChange` は
/// **Section ごとに配られる**。ここから矛盾する 2 つの対策が同居していた:
/// - 「開いた瞬間に 7 本走るので**仕事の方を畳む**」（`refreshInFlight` / `refreshRequested` /
///   `refreshRequestedFresh` の 3 つの旗）
/// - 「1 本だけ回す札は使うな。札を持つ Section がスクロールで消えるとループごと死ぬ」
///
/// ループの持ち主を `@State` のモデルへ移すと、どちらも**構造的に**起きない。
/// `@State` はビューの identity に紐づくので Section の再生成では作り直されず、Task の持ち主は
/// モデルなのでスクロールで死なない。7 回呼ばれても `ensureRunning` が 1 本に畳む。
///
/// ## 終わり方
/// 画面を閉じると `ensureRunning` が来なくなるので、`idleTimeout` 秒で自分から畳む
/// （`onDisappear` は**スクロールでも来る**ので使わない——それが上の矛盾の出発点だった）。
@MainActor
@Observable
final class AnalysisStatusModel {

    /// 数え直しの間隔（解析中）。
    private static let refreshInterval: TimeInterval = 4
    /// 画面が見られていないと判断するまでの猶予。
    private static let idleTimeout: TimeInterval = 60
    /// 候補の列挙（8.5 万件）を使い回す時間。定期の数え直しはカウントだけにする。
    private static let candidateReuse: TimeInterval = 60
    /// 解析が終わった/始まった瞬間の数え直しでも、直前に列挙したばかりなら使い回す。
    private static let edgeCandidateReuse: TimeInterval = 5

    private(set) var progress = AnalysisProgress(total: 0, embedded: 0, sceneTagged: 0)
    /// 顔スキャン: 候補（スクリーンショット除外・端末＋クラウド）のうち済んだ枚数と候補総数。
    /// ⚠️ 記録の総数÷ライブラリ総数では、削除済みの記録と候補外の写真で「存在しない残り」が出る。
    private(set) var faceScanned = 0
    private(set) var faceCandidates = 0
    private(set) var facesDetected = 0
    /// モデル更新の移行（ADR-186）: 旧モデルで作った埋め込みの残り／顔の影の世代の進み具合。
    private(set) var staleEmbeddings = 0
    private(set) var faceMigration: (scanned: Int, total: Int)?

    private var loop: Task<Void, Never>?
    private var lastSeen = Date()
    private var cachedCandidates: (keys: [String], at: Date)?

    struct Deps {
        let engine: AutoAlbumEngine
        let people: PeopleEngine
        let dropboxStore: DropboxPhotoStore
        let session: AnalysisSession
    }

    /// 画面が見えている合図。**何度呼ばれてもループは 1 本**。
    func ensureRunning(_ deps: Deps) {
        lastSeen = Date()
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.run(deps)
            self?.loop = nil
        }
    }

    private func run(_ deps: Deps) async {
        await refresh(deps, reuseCandidatesWithin: 0)
        // 直前のティックで解析中だったか（変化した瞬間を拾うため）。
        var wasAnalyzing = isAnalyzing(deps)
        var lastRefresh = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            // 画面が閉じられた（`ensureRunning` が来なくなった）。
            guard Date().timeIntervalSince(lastSeen) < Self.idleTimeout else { return }

            let analyzing = isAnalyzing(deps)
            // ⚠️ 始まった/終わった**瞬間**を拾う。以前はこれを `.onChange` 修飾子で取っていたが、
            // Section ごとに配られるうえスクロールでキャンセルされ、「完了直後の数字が凍る」
            // 症状を何度も出していた。ループが自分で辺を見れば取りこぼさない。
            let edge = analyzing != wasAnalyzing
            wasAnalyzing = analyzing
            let due = Date().timeIntervalSince(lastRefresh) >= Self.refreshInterval
            guard edge || (due && (analyzing || deps.session.isActive)) else { continue }
            lastRefresh = Date()
            await refresh(deps, reuseCandidatesWithin: edge ? Self.edgeCandidateReuse : Self.candidateReuse)
        }
    }

    private func isAnalyzing(_ deps: Deps) -> Bool {
        deps.engine.isTagging || BackgroundActivityMonitor.shared.isEmbedding || deps.people.isScanning
    }

    private func refresh(_ deps: Deps, reuseCandidatesWithin: TimeInterval) async {
        async let prog = deps.engine.analysisProgress()
        async let stats = deps.people.scanStats()
        progress = await prog
        facesDetected = await stats.faces
        // 顔スキャンの分母は**候補そのもの**（スキャナと同じ列挙）、分子は「候補のうち済んだ数」。
        if deps.people.isFaceModelAvailable {
            let candidates: [String]
            if let cached = cachedCandidates, Date().timeIntervalSince(cached.at) < reuseCandidatesWithin {
                candidates = cached.keys
            } else {
                candidates = await analysisOrderedRefKeys(dropboxStore: deps.dropboxStore)
                cachedCandidates = (candidates, Date())
            }
            let pending = await deps.people.pendingScanCount(candidateRefKeys: candidates)
            faceCandidates = candidates.count
            faceScanned = max(0, candidates.count - pending)
            faceMigration = await deps.people.faceModelMigrationProgress(candidateRefKeys: candidates)
        }
        staleEmbeddings = await deps.engine.pendingEmbeddingMigration()
    }
}
