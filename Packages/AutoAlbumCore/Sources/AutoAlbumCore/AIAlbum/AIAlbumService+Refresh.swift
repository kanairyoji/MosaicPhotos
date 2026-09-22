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

    /// この一枚岩の再評価を始めない/続けない条件（ADR-107 → ADR-196）。
    /// 前面復帰のほか、一括ロード・メモリ圧迫・生成中も降りる（どれも始めたら譲れないため）。
    /// 免除（デバッグ全開）はゲートの表の中で扱う。
    /// ⚠️ 判定は**重い段の前ごと**に見る。1 回だけ見る作りだと、判定と実処理の間に
    /// ユーザーが戻ってきたときに代金だけ払って捨てることになる（diagnostics-67）。
    private var shouldAbort: Bool {
        // 台帳と埋め込みを読むだけなので通信は要らない（Wi-Fi 待ちで止めない）。
        !BackgroundYield.allows(.localMonolith)
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
        guard !shouldAbort else {
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
        guard !shouldAbort else {
            Diagnostics.mark("aialbum.refresh: skipped — foreground (after load)")
            return current
        }
        let catalog = await Task.detached(priority: .utility) { AIAlbumCatalog.build(from: all) }.value
        // タグ台帳（タグ/OCR/人数/美的）も**ループの外で 1 つ**にする。中身はアルバムごとに
        // 変わらないのに、以前はアルバム 1 本ごとに全件（8.6 万行）を 2〜4 回引き直していた。
        // 遅延なので、条件を持つアルバムが無ければ 1 回も引かない（従来どおり）。
        let ledgers = AIAlbumLedgers(tagStore: tagStore)

        var updated: [AutoAlbumInfo] = []
        var skipped = 0
        for album in current {
            // 前面復帰したら次のアルバムへ進まない（一枚岩の途中放棄・ADR-107 の考え方）。
            // 背面で始まった refresh がユーザー復帰後も数分続き、体感フリーズになっていた
            // （diagnostics-48）。残りは現状のまま返し、次の夜間窓（stale 判定）が続きをやる。
            if shouldAbort {
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
            var (members, pool) = await rankedSearch(all, saved: saved, now: now, ledgers: ledgers)
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

    /// 人物の修正（「この写真は XX ではない」「別の人」・付け替え・統合）の直後に、
    /// **人物条件を持つ AI アルバムから、条件を満たさなくなった写真だけを外す**。
    ///
    /// ⚠️ 実フィードバック: AI アルバムで人違いを見つけて「XX ではない」を選んでも**変化なし**。
    /// 人物アルバムは顔クラスタを直接見るので即座に変わるが、AI アルバムのメンバーは
    /// 評価時のスナップショット（`memberRefs`）で、次の再評価（夜間・ドリフト）まで古いまま。
    /// 追加（新たに XX になった写真）は次の再評価に任せ、ここでは**外す**だけ——
    /// 既存メンバー × ハード条件の再判定だけなので速く、意味採点も LLM も走らない。
    /// - Returns: 変わったアルバムがあれば全体（順序は現状維持）、無ければ nil。
    func pruneAfterPeopleChange(_ current: [AutoAlbumInfo]) async -> [AutoAlbumInfo]? {
        guard !current.isEmpty else { return nil }
        let now = Date()
        var updated = current
        var touched = 0
        var dropped = 0
        // 名前表（全顔の射影）はアルバムごとに引かず、この 1 回で共有する。
        var sharedPeopleMap: [String: [String]]??
        // タグ台帳（美的・人数）も同じ理由で 1 回にする（全件 8.6 万行 × アルバム数だった）。
        let ledgers = AIAlbumLedgers(tagStore: tagStore)
        for (index, album) in current.enumerated() {
            guard let criteria = album.criteria, !criteria.isEmpty,
                  let saved = interpreter.saved(for: album.id), saved.criteria == criteria,
                  saved.spec.hasPeopleConditions, !album.memberRefs.isEmpty else { continue }
            let spec = saved.spec
            if sharedPeopleMap == nil { sharedPeopleMap = .some(await peopleMapIfNeeded(for: spec)) }
            guard let peopleMap = sharedPeopleMap ?? nil else { continue }
            let querySignals = await querySignalsIfNeeded(for: spec, ledgers: ledgers)
            let existing = await store.enrichedPhotos(forRefKeys: album.memberRefs)
            let kept = QueryEvaluator.hardFilter(existing, spec: spec, now: now,
                                                 peopleByRefKey: peopleMap, signals: querySignals)
            guard kept.count < existing.count else { continue }
            let members = kept.sorted { ($0.captureDate ?? .distantPast) > ($1.captureDate ?? .distantPast) }
            let info = AIAlbumSearcher.buildInfo(id: album.id, title: album.title,
                                                 interpretedTitle: saved.spec.title,
                                                 criteria: criteria, members: members,
                                                 aesthetics: await coverAesthetics(members),
                                                 usage: await coverUsage(members))
            await store.upsert(albumInfo: info)
            updated[index] = info
            touched += 1
            dropped += existing.count - kept.count
        }
        guard touched > 0 else { return nil }
        Diagnostics.mark("aialbum.peopleChange: \(touched) album(s) — dropped \(dropped) photo(s) that no longer match")
        return updated
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
        let photos = await store.enrichedPhotos(forRefKeys: newRefKeys)
        guard !photos.isEmpty else { return IncrementalResult(albums: current) }
        let batch = IncrementalBatch(
            refKeys: newRefKeys, photos: photos,
            vectors: await store.vectors(forRefKeys: newRefKeys),
            // 評価済み件数の頭打ちに使う（`AIAlbumIncremental.advancedEvaluatedCount`）。
            embeddedNow: await store.embeddedCount(), now: Date(),
            // 台帳（人数・美的）はアルバムをまたいで同じ。ループの外で 1 つにする。
            ledgers: AIAlbumLedgers(tagStore: tagStore))

        var updated = current
        var touched = 0
        /// 1 つでも採点できなかったアルバムがあれば、この分は待機列へ戻す。
        var deferred = false
        for (index, album) in current.enumerated() {
            guard let criteria = album.criteria, !criteria.isEmpty,
                  let saved = interpreter.saved(for: album.id), saved.criteria == criteria,
                  saved.evaluatedEmbedCount > 0 else { continue }
            let outcome = AIAlbumIncremental.isHardOnly(saved.spec)
                ? await incrementalHardOnly(album: album, criteria: criteria, saved: saved, batch: batch)
                : await incrementalSemantic(album: album, criteria: criteria, saved: saved, batch: batch)
            switch outcome {
            case .unchanged: break
            case .deferred: deferred = true
            case .updated(let info):
                updated[index] = info
                touched += 1
            }
        }
        if touched > 0 {
            Diagnostics.mark("aialbum.incremental: new=\(newRefKeys.count) touched=\(touched)/\(current.count)")
        }
        return IncrementalResult(albums: updated.sorted { $0.representativeDate > $1.representativeDate },
                                 deferredRefKeys: deferred ? newRefKeys : [])
    }

    /// 増分再評価の 1 回ぶんの材料（全アルバムで共有する）。
    struct IncrementalBatch {
        let refKeys: [String]
        let photos: [EnrichedPhoto]
        let vectors: [String: Data]
        let embeddedNow: Int
        let now: Date
        let ledgers: AIAlbumLedgers
    }

    /// 1 本のアルバムの増分再評価の結果。
    enum IncrementalOutcome {
        /// 足す写真が無かった（採点はした＝評価済み件数は進めてある）。
        case unchanged
        /// 採点できなかった（クエリ埋め込みが取れない）。**何も進めていない**＝待機列へ戻す。
        case deferred
        case updated(AutoAlbumInfo)
    }

    /// ハード条件だけで判定が完結するアルバム（ADR-109）。この経路では今回の新規分は評価済み。
    private func incrementalHardOnly(album: AutoAlbumInfo, criteria: String,
                                     saved: SavedInterpretation,
                                     batch: IncrementalBatch) async -> IncrementalOutcome {
        var saved = saved
        let spec = saved.spec
        saved.evaluatedEmbedCount = AIAlbumIncremental.advancedEvaluatedCount(
            saved.evaluatedEmbedCount, adding: batch.refKeys.count, embeddedNow: batch.embeddedNow)
        interpreter.save(saved, for: album.id)
        let passed = QueryEvaluator.hardFilter(
            batch.photos, spec: spec, now: batch.now,
            peopleByRefKey: await peopleMapIfNeeded(for: spec),
            signals: await querySignalsIfNeeded(for: spec, ledgers: batch.ledgers))
        let existing = Set(album.memberRefs)
        let newlyIn = passed.filter { !existing.contains($0.id) }
        guard !newlyIn.isEmpty else { return .unchanged }
        return .updated(await commitAddedMembers(album: album, criteria: criteria,
                                                 saved: saved, adding: newlyIn))
    }

    /// 意味採点をするアルバム。採点 → プールへ合流 → 線を越えた新規だけ証拠ゲートと LLM 審査 → 追加。
    private func incrementalSemantic(album: AutoAlbumInfo, criteria: String,
                                     saved: SavedInterpretation,
                                     batch: IncrementalBatch) async -> IncrementalOutcome {
        var saved = saved
        let spec = saved.spec
        let peopleMap = await peopleMapIfNeeded(for: spec)
        let faceCounts = await faceCountsIfNeeded(for: spec)
        // 人物証拠は humanCount（網羅率 約86%）を主軸に、顔スキャンを補助にする（ADR-100）。
        // ⚠️ フル評価と**同一の規則**にすること（食い違うと増分と全体で結果が変わる）。
        let humanCounts = faceCounts == nil ? [:] : (await batch.ledgers.humanCounts())
        // 属性条件のシグナルも増分評価で同一規則（S10）。
        let signals = await querySignalsIfNeeded(for: spec, ledgers: batch.ledgers)
        // 意味採点のクエリ埋め込み（キャッシュ）。取れないなら**何も進めずに**次回へ回す。
        // ⚠️ 評価済み件数は「採点できた」ときにだけ進める。先に進めると、モデルのロード失敗・
        // キャンセルの回の写真が**採点されていないのに評価済み**となり、ドリフト検知も
        // 差分ゼロと判断して二度と再評価されない（レビュー指摘）。
        guard let query = await queryVectors(for: saved) else {
            Diagnostics.mark("aialbum.incremental: query embedding unavailable — "
                + "deferring \(batch.refKeys.count) photo(s) for album \(album.id)")
            return .deferred
        }
        saved.evaluatedEmbedCount = AIAlbumIncremental.advancedEvaluatedCount(
            saved.evaluatedEmbedCount, adding: batch.refKeys.count, embeddedNow: batch.embeddedNow)
        // ハード条件＋意味採点（decode＋vDSP コサイン×新規枚数）は**オフメイン**で行う。
        // 増分再評価はフォアグラウンドの埋め込み進行中にも走るため、メインに載せると
        // 閲覧操作と CPU を奪い合う（ADR-43 系）。
        let (photos, vectors, now) = (batch.photos, batch.vectors, batch.now)
        let (passed, scores) = await Task.detached(priority: .utility) {
            AIAlbumIncremental.scoreNewPhotos(photos, vectors: vectors, spec: spec, now: now,
                                              peopleMap: peopleMap, signals: signals,
                                              faceCounts: faceCounts, humanCounts: humanCounts,
                                              query: query)
        }.value
        guard !passed.isEmpty, !scores.isEmpty else {
            interpreter.save(saved, for: album.id)
            return .unchanged
        }
        saved.scoredPool = AIAlbumSearcher.mergePool(saved.scoredPool, adding: scores)
        interpreter.save(saved, for: album.id)

        // 線を越えた新規だけメンバーへ追加（既存メンバーは維持・並びは日付降順で再構成）。
        let memberKeys = Set(AIAlbumSearcher.memberKeys(fromPool: saved.scoredPool))
        let existing = Set(album.memberRefs)
        let newlyIn = passed.filter { memberKeys.contains($0.id) && !existing.contains($0.id) }
        guard !newlyIn.isEmpty else { return .unchanged }
        // 増分の新規追加分も証拠ゲート → LLM 審査（小さいバッチ＝安価）。
        let gated = await verification.evidenceGatedIfExcluding(newlyIn, spec: spec)
        let verified = await verification.verified(gated, criteria: criteria)
        guard !verified.isEmpty else { return .unchanged }
        return .updated(await commitAddedMembers(album: album, criteria: criteria,
                                                 saved: saved, adding: verified))
    }

    /// 既存のメンバーに新しい写真を足し（日付降順）、アルバムを保存して返す。
    private func commitAddedMembers(album: AutoAlbumInfo, criteria: String,
                                    saved: SavedInterpretation,
                                    adding newlyIn: [EnrichedPhoto]) async -> AutoAlbumInfo {
        let existingPhotos = await store.enrichedPhotos(forRefKeys: album.memberRefs)
        let members = (existingPhotos + newlyIn)
            .sorted { ($0.captureDate ?? .distantPast) > ($1.captureDate ?? .distantPast) }
        let info = AIAlbumSearcher.buildInfo(id: album.id, title: album.title,
                                             interpretedTitle: saved.spec.title,
                                             criteria: criteria, members: members,
                                             aesthetics: await coverAesthetics(members),
                                             usage: await coverUsage(members))
        await store.upsert(albumInfo: info)
        return info
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
