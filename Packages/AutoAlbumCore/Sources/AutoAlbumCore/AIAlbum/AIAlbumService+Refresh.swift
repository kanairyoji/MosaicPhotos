import Foundation
import MosaicSupport
import PerceptionCore

// MARK: - 再評価（LLM なし）
//
// `AIAlbumService` のうち**再評価**（フル／増分／ドリフト検知）をここに分ける。
// 本体（`AIAlbumService.swift`）は作成・再設定・削除・本番化に専念する。
// ⚠️ 1 ファイル 680 行で「作る」と「作った後の維持」が同居していた。振る舞いは変えていない。

extension AIAlbumService {


    /// フル再評価：保存済み解釈で全写真を採点し直す（プール・評価済み枚数も更新）。
    /// LLM は走らない（解釈未保存のアルバムだけ初回に 1 回解釈して保存＝旧データの移行）。

    /// 前面に戻っていたら、この一枚岩の再評価は始めない/続けない（ADR-107）。
    /// 手動ブースト中とデバッグ全開は明示操作なので免除する。
    /// ⚠️ 判定は**重い段の前ごと**に見る。1 回だけ見る作りだと、判定と実処理の間に
    /// ユーザーが戻ってきたときに代金だけ払って捨てることになる（diagnostics-67）。
    private var shouldAbortForForeground: Bool {
        BackgroundYield.isAppActive && !BackgroundYield.debugForceHeavyWork
            && Date() >= BackgroundYield.manualBoostUntil
    }

    /// - Parameters:
    ///   - onlyDrifted: true なら**遅れているアルバムだけ**を作り直す（ADR-160）。
    ///     1 本の再評価が台帳の埋め込みを 1 周ぶん流すので、追いついている本まで巻き込むと
    ///     そのぶん丸ごと無駄な読み書きになる（実機 33 分で 1.07GB のディスク書き込み警告）。
    func refresh(_ current: [AutoAlbumInfo], onlyDrifted: Bool = false,
                 driftThreshold: Int = 500) async -> [AutoAlbumInfo] {
        guard !isEvaluating else {
            Diagnostics.mark("aialbum.refresh: skip — already evaluating")
            return current
        }
        isEvaluating = true
        defer { isEvaluating = false }
        Diagnostics.mark("aialbum.refresh: aiAlbums=\(current.count)")
        guard !current.isEmpty else { return current }
        // ⚠️ 前面判定は**重い前準備の前に**置く（実機 diagnostics-67）。以前はアルバムのループに
        // 入ってから初めて見ていたため、前面復帰していても台帳 86k 件の読み出し＋カタログ構築
        // （実測 12〜13 秒・footprint が 279→490MB）を払い切ってから `aborted for foreground (0/5)`
        // で捨てていた。**1 件も進まないのに毎ティック同じ代金を払う**形で、ドリフト条件
        // （embedded−evaluated > 500）は満たされたままなので永久に繰り返す。
        guard !shouldAbortForForeground else {
            Diagnostics.mark("aialbum.refresh: skipped — foreground (before load)")
            return current
        }
        let now = Date()
        let all = await store.allEnrichedPhotosLite()
        let embedCount = await store.embeddedCount()
        // 開始時の世代を控える（この後の長い await 中に削除・編集され得る）。
        let startedGenerations = Dictionary(uniqueKeysWithValues:
            current.map { ($0.id, generation(of: $0.id)) })
        // 再解釈（版更新）に備えてカタログを **1 回だけ**構築して全アルバムで共有する
        // （diagnostics-48: v7 移行の全再解釈がアルバムごとに 86k フェッチ＋カタログ構築を
        //  繰り返し、約 10 秒 × 5 本の負荷で前面のメインを飢餓させた）。
        // 読み出しの間に戻ってきていたら、カタログ構築（もう一度 86k 件を舐める）は始めない。
        guard !shouldAbortForForeground else {
            Diagnostics.mark("aialbum.refresh: skipped — foreground (after load)")
            return current
        }
        let catalog = await Task.detached(priority: .utility) { AIAlbumCatalog.build(from: all) }.value

        var updated: [AutoAlbumInfo] = []
        var skipped = 0
        for album in current {
            // 前面復帰したら次のアルバムへ進まない（一枚岩の途中放棄・ADR-107 の考え方）。
            // 背面で始まった refresh がユーザー復帰後も数分続き、体感フリーズになっていた
            // （diagnostics-48）。残りは現状のまま返し、次の夜間窓（stale 判定）が続きをやる。
            if shouldAbortForForeground {
                Diagnostics.mark("aialbum.refresh: aborted for foreground (\(updated.count)/\(current.count))")
                updated.append(contentsOf: current[updated.count...])
                break
            }
            guard let criteria = album.criteria, !criteria.isEmpty else { updated.append(album); continue }
            // 追いついているアルバムは触らない（触れば埋め込みを 1 周ぶん余計に流す）。
            if onlyDrifted, let saved = interpreter.saved(for: album.id),
               !AIAlbumDrift.needsFullEvaluation(version: saved.version, spec: saved.spec,
                                                 lastEvaluatedAt: saved.lastEvaluatedAt,
                                                 evaluatedEmbedCount: saved.evaluatedEmbedCount,
                                                 embedCount: embedCount, threshold: driftThreshold,
                                                 now: now) {
                skipped += 1
                updated.append(album)
                continue
            }
            var saved = await interpreter.interpretation(id: album.id, criteria: criteria, now: now,
                                                         baseLite: all, prebuiltCatalog: catalog)
            var (members, pool) = await rankedSearch(all, saved: saved, now: now)
            members = await verification.evidenceGatedIfExcluding(members, spec: saved.spec)
            members = await verification.verified(members, criteria: criteria)
            saved.scoredPool = pool
            saved.evaluatedEmbedCount = embedCount
            saved.lastEvaluatedAt = now
            guard await canCommit(id: album.id, criteria: criteria,
                                  generation: startedGenerations[album.id] ?? 0) else {
                Diagnostics.mark("aialbum.refresh: '\(criteria)' discarded (album deleted or edited)")
                continue
            }
            interpreter.save(saved, for: album.id)
            let info = AIAlbumSearcher.buildInfo(id: album.id, title: album.title, interpretedTitle: saved.spec.title,
                                                 criteria: criteria, members: members,
                                                 aesthetics: await coverAesthetics(members),
                                                 usage: await coverUsage(members))
            await store.upsert(albumInfo: info)
            updated.append(info)
        }
        Diagnostics.mark("aialbum.refresh: done — evaluated=\(current.count - skipped)/\(current.count) "
                         + "skipped=\(skipped)（追いついている本は流さない）")
        return updated.sorted { $0.representativeDate > $1.representativeDate }
    }

    /// 増分再評価（Phase 2）：**新規に埋め込まれた refKey 群だけ**を採点してプールへマージし、
    /// 閾値を超えた写真をメンバーへ追加する。全ベクトルのページ走査・LLM は一切行わない。
    /// 解釈やプールが未保存のアルバムは触らない（ドリフト検知のフル再評価に任せる）。
    /// 増分再評価の結果。**採点できなかった分**（クエリ埋め込みが取れなかった等）を
    /// 呼び出し側へ返し、待機列へ戻せるようにする。
    ///
    /// ⚠️ 戻さないと、その refKey は評価済みにもならず待機列にも残らないため、
    /// 追加枚数がドリフト閾値を超えるまで**アルバムへ入らないまま**になる（レビュー指摘）。
    struct IncrementalResult: Sendable {
        var albums: [AutoAlbumInfo]
        var deferredRefKeys: [String] = []
    }

    func refreshIncremental(newRefKeys: [String],
                            current: [AutoAlbumInfo]) async -> IncrementalResult {
        guard !current.isEmpty, !newRefKeys.isEmpty else { return IncrementalResult(albums: current) }
        let now = Date()
        let newPhotos = await store.enrichedPhotos(forRefKeys: newRefKeys)
        let newVectors = await store.vectors(forRefKeys: newRefKeys)
        guard !newPhotos.isEmpty else { return IncrementalResult(albums: current) }

        var updated = current
        var touched = 0
        /// 1 つでも採点できなかったアルバムがあれば、この分は待機列へ戻す。
        var deferred = false
        // 評価済み件数は現実（埋め込み総数）を超えないよう頭打ちにする。待機列へ戻した分を
        // 再処理すると、既に数えたアルバムで二重加算になり得るため。
        let embeddedNow = await store.embeddedCount()
        for (index, album) in current.enumerated() {
            guard let criteria = album.criteria, !criteria.isEmpty,
                  var saved = interpreter.saved(for: album.id), saved.criteria == criteria,
                  saved.evaluatedEmbedCount > 0 else { continue }

            // ハード条件の適用＋意味採点（decode＋vDSP コサイン×新規枚数）は**オフメイン**で行う。
            // 増分再評価はフォアグラウンドの埋め込み進行中にも走るため、メインに載せると
            // 閲覧操作と CPU を奪い合う（AI アルバム見直しの一環・ADR-43 系）。
            let spec = saved.spec
            let peopleMap = await peopleMapIfNeeded(for: spec)
            let faceCounts = await faceCountsIfNeeded(for: spec)
            // 人物証拠は humanCount（網羅率 約86%）を主軸に、顔スキャンを補助にする（ADR-100）。
            // ⚠️ フル評価と**同一の規則**にすること（食い違うと増分と全体で結果が変わる）。
            let humanCounts = faceCounts == nil ? [:] : (await tagStore?.allHumanCounts() ?? [:])
            // 属性条件のシグナルも増分評価で同一規則（S10）。
            let querySignals = await querySignalsIfNeeded(for: spec)
            // ⚠️ 評価済み件数は「採点できた」ときにだけ進める。先に進めてしまうと、
            // クエリ埋め込みが取れなかった回（モデルのロード失敗・キャンセル）の写真が
            // **採点されていないのに評価済み**となり、ドリフト検知も差分ゼロと判断して
            // 二度と再評価されない（レビュー指摘）。
            // 内容の意図が実効的に無い（内容語が全部ハード接地語・除外も無し）アルバムは、
            // フル評価（searchWithPool）と同じく**ハード通過分をそのまま追加**する（ADR-109）。
            // 英訳文で意味採点すると「太郎」だけのアルバムに新規の太郎写真が入らないことがある。
            let effective = spec.effectiveContentTerms
            if effective.include.isEmpty && effective.exclude.isEmpty
                && spec.hasHardConstraints {
                // この経路はハード条件だけで判定が完結する＝今回の新規分は評価済み。
                saved.evaluatedEmbedCount = min(saved.evaluatedEmbedCount + newRefKeys.count,
                                                max(saved.evaluatedEmbedCount, embeddedNow))
                interpreter.save(saved, for: album.id)
                let base = QueryEvaluator.hardFilter(newPhotos, spec: spec, now: now,
                                                     peopleByRefKey: peopleMap, signals: querySignals)
                let existing = Set(album.memberRefs)
                let newlyIn = base.filter { !existing.contains($0.id) }
                guard !newlyIn.isEmpty else { continue }
                let existingPhotos = await store.enrichedPhotos(forRefKeys: album.memberRefs)
                let members = (existingPhotos + newlyIn)
                    .sorted { ($0.captureDate ?? .distantPast) > ($1.captureDate ?? .distantPast) }
                let info = AIAlbumSearcher.buildInfo(id: album.id, title: album.title,
                                                     interpretedTitle: saved.spec.title,
                                                     criteria: criteria, members: members,
                                                     aesthetics: await coverAesthetics(members),
                                                     usage: await coverUsage(members))
                await store.upsert(albumInfo: info)
                updated[index] = info
                touched += 1
                continue
            }
            // 意味採点のクエリ埋め込み（キャッシュ）。取れないなら**何も進めずに**次回へ回す
            // （評価済みにしてしまうと、この写真たちは二度と採点されない）。
            guard let q = await queryVectors(for: saved) else {
                Diagnostics.mark("aialbum.incremental: query embedding unavailable — "
                    + "deferring \(newRefKeys.count) photo(s) for album \(album.id)")
                deferred = true
                continue
            }
            // ここから先は採点できる。今回の新規分を評価済みに数える
            // （待機列へ戻した分の再処理で二重加算しないよう、現実の埋め込み総数で頭打ち）。
            saved.evaluatedEmbedCount = min(saved.evaluatedEmbedCount + newRefKeys.count,
                                            max(saved.evaluatedEmbedCount, embeddedNow))
            let (base, added) = await Task.detached(priority: .utility) {
                () -> ([EnrichedPhoto], [String: Float]) in
                // ハード条件（相対日付は now で解決）を新規分に適用。
                var base = QueryEvaluator.hardFilter(newPhotos, spec: spec, now: now,
                                                     peopleByRefKey: peopleMap, signals: querySignals)
                // 人系の除外があれば実測の人数でハード除外（フル評価と同じ規則・ADR-100）。
                // 証拠が無い写真は通さない（「無い＝いない」と読まない）。
                if faceCounts != nil {
                    base = base.filter { photo in
                        if let human = humanCounts[photo.id] { return human == 0 }
                        if let faces = faceCounts?[photo.id] { return faces == 0 }
                        return false
                    }
                }
                var added: [String: Float] = [:]
                for photo in base {
                    guard let data = newVectors[photo.id], let v = ClipMath.decode(data) else { continue }
                    // 採点規則（max-over-probes＋除外の相対判定）はフル評価と同一（QueryEmbedder に一元化）。
                    guard let pos = QueryEmbedder.semanticScore(q, photoVector: v) else { continue }
                    added[photo.id] = pos
                }
                return (base, added)
            }.value
            guard !base.isEmpty else { interpreter.save(saved, for: album.id); continue }
            guard !added.isEmpty else { interpreter.save(saved, for: album.id); continue }

            saved.scoredPool = AIAlbumSearcher.mergePool(saved.scoredPool, adding: added)
            interpreter.save(saved, for: album.id)

            // 閾値を超えた新規だけメンバーへ追加（既存メンバーは維持・並びは日付降順で再構成）。
            let memberKeys = Set(AIAlbumSearcher.memberKeys(fromPool: saved.scoredPool))
            let existing = Set(album.memberRefs)
            let newlyIn = base.filter { memberKeys.contains($0.id) && !existing.contains($0.id) }
            guard !newlyIn.isEmpty else { continue }

            // P2: 増分の新規追加分も証拠ゲート → LLM 審査（小さいバッチ＝安価）。
            let gatedNew = await verification.evidenceGatedIfExcluding(newlyIn, spec: saved.spec)
            let verifiedNew = await verification.verified(gatedNew, criteria: criteria)
            guard !verifiedNew.isEmpty else { continue }
            let existingPhotos = await store.enrichedPhotos(forRefKeys: album.memberRefs)
            let members = (existingPhotos + verifiedNew)
                .sorted { ($0.captureDate ?? .distantPast) > ($1.captureDate ?? .distantPast) }
            let info = AIAlbumSearcher.buildInfo(id: album.id, title: album.title, interpretedTitle: saved.spec.title,
                                                 criteria: criteria, members: members,
                                                 aesthetics: await coverAesthetics(members),
                                                 usage: await coverUsage(members))
            await store.upsert(albumInfo: info)
            updated[index] = info
            touched += 1
        }
        if touched > 0 {
            Diagnostics.mark("aialbum.incremental: new=\(newRefKeys.count) touched=\(touched)/\(current.count)")
        }
        return IncrementalResult(albums: updated.sorted { $0.representativeDate > $1.representativeDate },
                                 deferredRefKeys: deferred ? newRefKeys : [])
    }

    /// ドリフト検知：保存済みの評価時点と現在の埋め込み枚数の差が `threshold` を超えていたら
    /// フル再評価する（アイドル時のティックから呼ぶ）。差が小さければ nil（何もしない）。
    /// 解釈未保存のアルバム（旧データ）は evaluated=0 扱いになるため、ここで初回移行も担う。
    func refreshIfDrifted(_ current: [AutoAlbumInfo], threshold: Int = 500) async -> [AutoAlbumInfo]? {
        guard !current.isEmpty else { return nil }
        // 解釈器の版が古いアルバムがあれば、埋め込みの進行に関係なくフル再評価する
        // （評価**規則**の変更＝v7 実効内容語のような修正を、既存アルバムへ確実に波及させる）。
        let stale = current.contains { album in
            guard let saved = interpreter.saved(for: album.id) else { return false }
            return saved.version != SavedInterpretation.currentVersion
        }
        // 「直近 30 日」等は**時間が経つだけで範囲が動く**。写真が増えなくても、日付が変わったら
        // 再評価する（増分は既存メンバーを維持するので、期間外の写真が残り続ける・レビュー指摘）。
        let now = Date()
        let dateMoved = current.contains { album in
            guard let saved = interpreter.saved(for: album.id) else { return false }
            return RelativeDateStaleness.needsRefresh(spec: saved.spec,
                                                      lastEvaluatedAt: saved.lastEvaluatedAt,
                                                      now: now)
        }
        let embedCount = await store.embeddedCount()
        let evaluated = interpreter.minEvaluatedEmbedCount(for: current.map(\.id))
        guard stale || dateMoved || embedCount - evaluated > threshold else { return nil }
        // ⚠️ **遅れている本だけ**作り直す（ADR-160）。ここは「1 本でも遅れていれば起動する」
        // 判定で、作り直す対象の選別は `refresh(onlyDrifted:)` がアルバム単位で行う。
        Diagnostics.mark("aialbum.drift: embedded=\(embedCount) evaluated=\(evaluated) "
                         + "stale=\(stale) dateMoved=\(dateMoved) → refresh (drifted only)")
        return await refresh(current, onlyDrifted: true, driftThreshold: threshold)
    }

    func clearCache() {
        interpreter.removeAll()
        queryVectorCache = [:]
    }

    /// 再解析（全埋め込み作り直し）時：解釈は保持し、評価状態だけリセットする。
    func resetEvaluationState() {
        interpreter.resetEvaluationStates()
        queryVectorCache = [:]
    }
}
