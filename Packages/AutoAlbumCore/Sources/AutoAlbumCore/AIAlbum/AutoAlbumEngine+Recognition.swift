import PerceptionCore
import Foundation
import MosaicSupport
import PhotoSourceKit

/// `AutoAlbumEngine` の「AI アルバム / 認識タグ付け / フル画像 insight」関連を分離した extension。
/// 生成オーケストレーション本体（`AutoAlbumEngine.swift`）から切り離し、`AIAlbumService` と
/// `PhotoTagger` への委譲をここに集約する。
extension AutoAlbumEngine {

    // MARK: - Photo insight (フル画像ビュー表示用)

    /// 写真（`PhotoItem.id`）の付加情報（キャプション/人物/解析状態）。フル画像ビューの表示用。
    /// `id` の形式はソースで異なる：MergedPhotoItem は既に "L-…"/"C-…"（refKey そのもの）、
    /// LocalPhotoItem は生の localIdentifier、DropboxFileItem は生の path。すべてに対応する。
    public func insight(forItemID id: String) async -> PhotoInsight? {
        let keys = Self.candidateRefKeys(for: id)
        for refKey in keys {
            guard let rec = await store.insightRecord(refKey: refKey) else { continue }
            let status: PhotoInsight.Status = rec.tagged ? .ready : .analyzing
            // A4 パフォーマンス: タグ・キャプションの照会を**並列**で発行する（旧: 直列 await ×3
            // ＝スワイプ連打時のパネル表示遅延）。CLIP 表示ラベルも rec を得た時点で並行に走らせる。
            async let tagsTask = tagStore.tags(forRefKeys: [refKey])
            async let captionTask = tagStore.captions(forRefKeys: [refKey])
            async let ocrTask = tagStore.ocrTexts(forRefKeys: [refKey])
            async let usageTask = usageStore.counts(forRefKeys: [refKey])
            // CLIP 表示ラベルは**準備できているときだけ**合成する。未構築だと labels() が CLIP テキスト
            // タワーのロード（初回〜数十秒）＋約300語構築を同期で走らせ、insight が返らず（パネルが
            // 空/loading のまま）になる（実測: 画像タワー 34s）。prewarm 完了までは Vision タグだけで即返す。
            async let clipLabelsTask: [String] = {
                if let vector = rec.photo.clipVector, let labelProvider, labelProvider.isReady {
                    return await labelProvider.labels(forEmbedding: vector)
                }
                return []
            }()
            // タグ表示は Vision シーンタグ（校正済み・検索と同一の台帳）を第一に、
            // CLIP ゼロショットの表示ラベルで補完する（重複除去・最大10個）。
            var tags = (await tagsTask)[refKey] ?? []
            let clipLabels = await clipLabelsTask
            if !clipLabels.isEmpty {
                let seen = Set(tags.map { $0.lowercased() })
                tags += clipLabels.filter { !seen.contains($0.lowercased()) }
            }
            let caption = (await captionTask)[refKey]
            let hasCaption = caption?.isEmpty == false
            // キャプションは**お気に入り限定**なので、「生成中」は VLM 同梱かつ未生成かつ**お気に入り**のときだけ出す
            // （非お気に入りは今後も付かないので空欄でよい・誤って「生成中」を出さない）。
            let captionPending = !hasCaption && tagTagger.isCaptioningAvailable && favoritesCache.contains(refKey)
            let ocrText = (await ocrTask)[refKey]
            let usage = (await usageTask)[refKey]
            return PhotoInsight(tags: Array(tags.prefix(10)), people: rec.photo.people,
                                caption: hasCaption ? caption : nil,
                                captionPending: captionPending,
                                ocrText: ocrText,
                                viewCount: usage?.viewCount,
                                playCount: usage?.playCount,
                                shareCount: usage?.shareCount,
                                isScreenshot: rec.photo.isScreenshot,
                                status: status)
        }
        // 付加情報が無い＝まだ取り込まれていない。
        return PhotoInsight(status: .notIndexed)
    }

    // MARK: - 利用カウンタ（閲覧/再生/共有）

    /// 利用イベントを記録する（フル画面の閲覧・共有シートの完了・将来の再生）。
    /// `id` は insight と同じくソースにより形式が違うため、正規の refKey に解決して記録する。
    public func recordUsage(_ kind: PhotoUsageEventKind, itemID id: String) async {
        await usageStore.increment(kind, refKey: Self.canonicalRefKey(for: id))
    }

    /// 生 id → 正規 refKey。既に "L-…"/"C-…" ならそのまま、Dropbox パス（"/" 始まり）は
    /// cloud、それ以外（PHAsset の localIdentifier）は local としてエンコードする。
    /// （public: アプリ側のベストショット判定＝photoQualityProvider でも使う）
    public nonisolated static func canonicalRefKey(for id: String) -> String {
        if PhotoRef.decode(id) != nil { return id }
        return id.hasPrefix("/") ? PhotoRef.cloud(id).encoded : PhotoRef.local(id).encoded
    }

    // MARK: - ベストショット（きれいな写真）判定

    /// 「ベストショット」とみなす写真の refKey 集合（サムネイルグリッドのフィルタ用）。
    /// 判定＝ Vision 美的スコア（`VNCalculateImageAestheticsScoresRequest`・-1〜1・夜間タグ付けで
    /// 全写真に付与）が `PhotoQuality.beautifulThreshold` 以上、かつスクリーンショットでない。
    /// スコア未付与（解析待ち）の写真は含めない＝解析が進むほど対象が増える。
    public func beautifulPhotoKeys() async -> Set<String> {
        let good = await tagStore.refKeys(aestheticAtLeast: PhotoQuality.beautifulThreshold)
        guard !good.isEmpty else { return [] }
        let screenshots = await store.screenshotRefKeys()
        return good.subtracting(screenshots)
    }

    /// id（生 localIdentifier / 生 path / 既に refKey）→ 試す refKey 候補。
    private static func candidateRefKeys(for id: String) -> [String] {
        var keys: [String] = []
        if PhotoRef.decode(id) != nil { keys.append(id) }
        keys.append(PhotoRef.local(id).encoded)
        keys.append(PhotoRef.cloud(id).encoded)
        return keys
    }

    // MARK: - AI albums

    public func createAIAlbum(title: String, criteria: String) async -> AIAlbumResult {
        await makeAIAlbum(id: "\(AIAlbumStrategy.strategyID):\(UUID().uuidString)", title: title, criteria: criteria)
    }

    /// 既存 AI アルバムを再設定（タイトル・条件を変更して作り直す）。id を維持して上書きする。
    public func updateAIAlbum(id: String, title: String, criteria: String) async -> AIAlbumResult {
        await makeAIAlbum(id: id, title: title, criteria: criteria)
    }

    /// AI アルバムの作成/更新を**バックグラウンドで**開始する（UI を待たせない）。
    /// コンポーザーはこれを呼んで即 dismiss してよい。進捗は `isMakingAIAlbum`（ヘッダーのスピナー）と
    /// 完了時の `aiAlbums` 更新で反映される。`id == nil` なら新規作成、指定ありなら再設定。
    /// 検索文が空なら何もしない（コンポーザー側でもボタンを無効化しているが二重に防ぐ）。
    public func beginMakeAIAlbum(id: String?, title: String, criteria: String) {
        guard !criteria.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isMakingAIAlbum = true
        // ユーザーが結果を待っている操作なので userInitiated（既定優先度だと背景タグ付けと同格になる）。
        Task(priority: .userInitiated) {
            defer { isMakingAIAlbum = false }
            if let id {
                _ = await updateAIAlbum(id: id, title: title, criteria: criteria)
            } else {
                _ = await createAIAlbum(title: title, criteria: criteria)
            }
        }
    }

    /// コンポーザー表示時の事前準備（体感速度）: CLIP テキストタワーの遅延ロードを入力中に
    /// 済ませておく（未ロードだと「作成」タップ後の検索フェーズに初回ロードが乗る）。
    /// スナップショット（全メタ）はコンポーザーの `albumSuggestions()` 呼び出しが構築する。
    public func prepareAIComposer() {
        // utility: ウォームアップは急がない。userInitiated だとシートの開閉アニメーションと
        // CPU を奪い合ってもたつく（実障害）。ロード自体も embedder 側で utility 実行。
        Task(priority: .utility) {
            await aiService.prewarmTextEmbedder()
        }
    }

    public func deleteAIAlbum(id: String) async {
        aiAlbums = await aiService.delete(id: id)
    }

    private func makeAIAlbum(id: String, title: String, criteria: String) async -> AIAlbumResult {
        // コンポーザーがチップ/接地プレビュー用に構築済みのスナップショットを渡し、
        // make 内の全メタ再フェッチ（数万件の SwiftData fetch＝最重量部）を省く。
        // 鮮度は件数変化で管理される（A5・コンポーザー表示のたびに検証済み）。make は常に
        // コンポーザー経由なので実質最新。保険として 30 分の上限だけ残す。
        let lite: [EnrichedPhoto]? = {
            guard let snap = suggestionSnapshot,
                  Date().timeIntervalSince(snap.builtAt) < 1800 else { return nil }
            return snap.lite
        }()
        let (result, albums) = await aiService.make(id: id, title: title, criteria: criteria,
                                                    baseLite: lite)
        if let albums { aiAlbums = albums }
        if case .created = result { scheduleBackgroundFill() }   // 取り込み途中でも背景で埋める
        return result
    }

    /// 保存済み AI アルバムを現在のインデックスで再評価する。
    func refreshAIAlbums() async {
        aiAlbums = await aiService.refresh(aiAlbums)
    }

    /// デバッグ（Developer Options）: AI アルバムの**フル再評価**を即時実行する
    /// （通常はドリフト検知＝アイドル時のみ。動作検証用）。
    public func debugRefreshAIAlbumsFull() async {
        await refreshAIAlbums()
    }

    /// Phase 2: 埋め込み進行に伴う再評価は**増分**（新規 refKeys だけ採点してプールへマージ）。
    /// 全ベクトルのページ走査（~13MB/回）も LLM も走らない。時間スロットル（5 分）で頻度も抑える
    /// （スロットル中は refKeys を蓄積し、次回にまとめて処理＝取りこぼしなし）。
    func refreshAIAlbumsThrottled(newRefKeys: [String]) async {
        pendingNewEmbeds.append(contentsOf: newRefKeys)
        let remaining = BackgroundActivityMonitor.shared.embedRemaining
        if remaining > 0, Date().timeIntervalSince(lastAIRefreshAt) < 300 { return }
        lastAIRefreshAt = Date()
        let pending = pendingNewEmbeds
        pendingNewEmbeds = []
        guard !pending.isEmpty else { return }
        aiAlbums = await aiService.refreshIncremental(newRefKeys: pending, current: aiAlbums)
    }

    // MARK: - Recognition (Vision/CLIP タグ付け)

    /// 未タグ写真の Vision タグ付け＋AI アルバム再評価をバックグラウンドで進める（非ブロッキング）。
    /// QoS は `.background`：UI 操作（.userInitiated）と CPU を奪い合わず、OS が優先度を下げる。
    /// 未タグ写真の Vision タグ付け＋CLIP 埋め込み＋VLM キャプションをバックグラウンドで進める。
    /// ※ 一時停止で滞留したタスクは、ゲートが開けば（`heavyShouldPause` が false になれば）内部の
    ///   `waitWhilePaused` で**自分で再開**する。生成フラグ滞留の安全弁は
    ///   `BackgroundActivityMonitor.isGeneratingAlbums`（時間失効）とデバッグ全開バイパスが担う。
    public func scheduleBackgroundFill() {
        // D: 二重起動の抑止。前景の起動タスクと夜間 BGTask が同じエンジンに対して同時に呼び得るため、
        //    実行中フラグを**同期的に**立ててから Task を起こす（Task 内で立てると 2 本すり抜ける）。
        // 一時停止で滞留したタスクはゲートが開けば内部の waitWhilePaused で自分で再開する（force 撤去）。
        // 真因の画像ロードハング（PHAssetImageLoader）は修正済みなので、以前 isTagging を握り続けていた
        // launch タスクも自力で解けて完了する。
        guard !isTagging else {
            Diagnostics.mark("bgfill: skip — already tagging/embedding")
            return
        }
        isTagging = true
        let preset = Self.currentBackgroundPreset()
        Task(priority: .background) {
            defer { isTagging = false }
            Diagnostics.mark("bgfill: begin (pause=\(BackgroundYield.heavyShouldPause()) "
                             + "generating=\(BackgroundActivityMonitor.shared.isGeneratingAlbums))")
            // 表示ラベラの概念埋め込み（約300語）は**別タスクで前もって温める**（fire-and-forget）。
            // ANE 直列化ゲートは encodeText の内側で**1 語ずつ**取る（ADR-73）。ここでまとめて包むと
            // 約300語ぶんゲートを握り続け、その間の顔スキャン・タグ付けが完全に止まる。
            Task(priority: .background) { [weak self] in
                guard let self, let labeler = self.labelProvider else { return }
                await labeler.prewarm()
            }
            // お気に入り集合を先に取り込み、全解析の**処理順（お気に入り優先）**に使う（変化するので毎回更新）。
            await refreshFavoritesCache()
            let favorites = favoritesCache
            // P1: まずシーンタグ（Vision・数十ms/枚＝速い）を全量に行き渡らせる。
            // タグは検索の一次ランキングなので、CLIP 埋め込みより先に揃える価値が高い。
            // 候補は **お気に入り(ローカル→クラウド)→その他(ローカル→クラウド)・各新→古**（AnalysisOrder）。
            // クラウド写真のタグ付けはサムネDLを要するため、回線NG（Wi-Fi 待ち等）なら今回はローカルのみ
            // （Wi-Fi 復帰後の次回にクラウド分を拾う）。ローカルは通信不要なので常に進む（Fix B）。
            let tagNetOK = NetworkStateMonitor.shared.networkAllowed()
            let tagPool = await store.enrichedRefKeysNewestFirst()
            let candidates = AnalysisOrder.ordered(tagNetOK ? tagPool : tagPool.filter { $0.hasPrefix("L-") },
                                                   favorites: favorites)
            await tagTagger.tagUnprocessed(candidateRefKeys: candidates,
                                           shouldPause: { BackgroundYield.heavyShouldPause() })
            // P2/P3: CLIP 埋め込みと VLM キャプションを**インターリーブ**で進める。
            // ⚠️ 逐次（埋め込み全量→キャプション）だと、埋め込みが 85k 枚すべて終わるまで
            //    キャプションが 1 枚も始まらない（実測 21% で滞留＝キャプション永遠に未着手）。
            //    そこで両者を少量ずつ交互に回し、どちらも進捗しなくなったら終了する。
            let embedPause: @MainActor () -> Bool = { [weak self] in
                // 重い処理の共通方針（電源接続＋低電力OFF＋一定時間アイドル＋生成との相互排他）は
                // BackgroundYield.heavyShouldPause に一元化。埋め込みは操作中も譲る。
                (self?.isInteracting ?? false) || BackgroundYield.heavyShouldPause()
            }
            let captionPause: @MainActor () -> Bool = { BackgroundYield.heavyShouldPause() }
            // VLM キャプション（重い文章生成）は**お気に入り限定**（favorites は上で取り込み済み）。
            // 処理順は**撮影日降順**（新しい写真から先に説明が付く）。
            let favoritesOrdered = await store.newestFirst(refKeys: favorites)
            Diagnostics.mark("bgfill: embed loop entry (pause=\(BackgroundYield.heavyShouldPause()) "
                             + "generating=\(BackgroundActivityMonitor.shared.isGeneratingAlbums) "
                             + "unembedded=\(await store.unembeddedCount()))")
            while !BackgroundYield.heavyShouldPause() {
                let embedBefore = await store.unembeddedCount()
                await tagger.embedUnprocessed(batchSize: preset.batchSize,
                                              betweenBatchNs: preset.betweenBatchNs,
                                              maxBatches: 12,
                                              favorites: favorites,
                                              shouldPause: embedPause,
                                              networkAllowed: { NetworkStateMonitor.shared.networkAllowed() },
                                              onProgress: { BackgroundActivityMonitor.shared.embedRemaining = $0 }) {
                    [weak self] newKeys in await self?.refreshAIAlbumsThrottled(newRefKeys: newKeys)
                }
                let embedAfter = await store.unembeddedCount()
                if BackgroundYield.heavyShouldPause() { break }
                // 1-b: VLM(≈877MB) は**顔スキャンが動いていない間だけ**回す（facenet と同時常駐させない）。
                // 顔スキャン中はキャプションを見送り、埋め込みだけ進める（お気に入りキャプションは最優先で
                // ないので次の窓で拾う）。これでモデル同時常駐のピークを抑える。
                var capBefore = 0, capAfter = 0
                if !BackgroundActivityMonitor.shared.isScanningFaces {
                    capBefore = await tagStore.captionPendingCount(favorites: favorites)
                    await tagTagger.captionUnprocessed(maxBatches: 3, favoritesNewestFirst: favoritesOrdered,
                                                       shouldPause: captionPause)
                    capAfter = await tagStore.captionPendingCount(favorites: favorites)
                    // 1-d: キャプションフェーズが一巡したら VLM を解放（CLIP 画像塔と同時常駐しない）。
                    tagTagger.releaseCaptionModel()
                }
                // どちらも 1 枚も進まなかった＝残作業なし（お気に入り分のキャプション完了含む）→ 終了。
                let progressed = (embedAfter < embedBefore) || (capAfter < capBefore)
                if !progressed { break }
            }
            // ループを抜けたら VLM は必ず解放しておく（顔スキャン中でキャプション未実行だった場合も）。
            tagTagger.releaseCaptionModel()
            // isTagging は先頭の defer で必ず戻す（二重起動抑止と対）。
        }
    }

    /// 設定（重さ段階）から現在のバックグラウンド埋め込みプリセットを読む。
    static func currentBackgroundPreset() -> BackgroundProcessingPreset {
        let index = UserDefaults.standard.object(forKey: AutoAlbumSettingsKeys.backgroundProcessingLevel) as? Int
            ?? BackgroundProcessing.defaultIndex
        return BackgroundProcessing.preset(at: index)
    }

    /// refKey → 生成済み VLM キャプション。バックアップの metadata 保全（ADR-38）などアプリ側から使う。
    public func captions(forRefKeys keys: [String]) async -> [String: String] {
        await tagStore.captions(forRefKeys: keys)
    }

    /// キャプション済みの写真サンプル（refKey・説明文）。設定「AIによる説明」の確認 UI 用。
    /// VLM キャプションが実際に付いているかを、生成された説明文で目視確認できるようにする。
    public func captionedSamples(limit: Int = 200) async -> [(refKey: String, caption: String)] {
        await tagStore.captionedSamples(limit: limit)
    }

    /// 埋め込み済み／未処理の写真数（設定画面の進捗表示用）。
    public func recognitionCounts() async -> (tagged: Int, untagged: Int) {
        async let tagged = store.embeddedCount()
        async let untagged = store.unembeddedCount()
        return (await tagged, await untagged)
    }

    /// 画像解析の進捗スナップショット（ユーザー向け「AI 解析の状況」画面用）。
    /// `total`（取り込み済み写真数＝分母）と、各パスの完了数を 1 回で取得する。
    /// 完了時刻は `AnalysisActivity.lastActivity(_:)` で別途読む（UserDefaults・同期）。
    public func analysisProgress() async -> AnalysisProgress {
        await refreshFavoritesCache()
        let favorites = favoritesCache
        async let total = store.enrichmentCount()
        async let embedded = store.embeddedCount()
        async let tagged = tagStore.taggedCount()
        // キャプションはお気に入り限定なので、済み枚数もお気に入り分（=お気に入り総数−未生成）で数える。
        async let capPending = tagStore.captionPendingCount(favorites: favorites)
        let captionedFav = max(0, favorites.count - (await capPending))
        return AnalysisProgress(total: await total, embedded: await embedded,
                                sceneTagged: await tagged, captioned: captionedFav,
                                captionableTotal: favorites.count)
    }

    /// 全写真の認識結果（CLIP 埋め込み・キャプション）を消去し、最新ロジックで一から付け直す。
    /// 「再解析」用。完了まで await する（UI はスピナー表示）。
    public func reanalyzePhotos() async {
        guard !isTagging else { return }
        await store.clearPerception()
        // 埋め込みを全消しするので、AI アルバムの評価状態（プール）もリセットする（解釈は保持）。
        aiService.resetEvaluationState()
        await refreshFavoritesCache()
        let favorites = favoritesCache
        let preset = Self.currentBackgroundPreset()
        isTagging = true
        await tagger.embedUnprocessed(batchSize: preset.batchSize,
                                      betweenBatchNs: preset.betweenBatchNs,
                                      favorites: favorites,
                                      shouldPause: { [weak self] in
                                          (self?.isInteracting ?? false) || MemoryPressureMonitor.shared.isUnderPressure
                                      },
                                      onProgress: { BackgroundActivityMonitor.shared.embedRemaining = $0 }) {
            [weak self] newKeys in await self?.refreshAIAlbumsThrottled(newRefKeys: newKeys)
        }
        isTagging = false
    }
}
