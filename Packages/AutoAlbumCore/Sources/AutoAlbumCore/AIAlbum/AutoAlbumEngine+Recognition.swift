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
            // タグ表示は Vision シーンタグ（校正済み・検索と同一の台帳）を第一に、
            // CLIP ゼロショットの表示ラベルで補完する（重複除去・最大10個）。
            var tags = (await tagStore.tags(forRefKeys: [refKey]))[refKey] ?? []
            // CLIP 表示ラベルは**準備できているときだけ**合成する。未構築だと labels() が CLIP テキスト
            // タワーのロード（初回〜数十秒）＋約300語構築を同期で走らせ、insight が返らず（パネルが
            // 空/loading のまま）になる（実測: 画像タワー 34s）。prewarm 完了までは Vision タグだけで即返す。
            if let vector = rec.photo.clipVector, let labelProvider, labelProvider.isReady {
                let clipLabels = await labelProvider.labels(forEmbedding: vector)
                let seen = Set(tags.map { $0.lowercased() })
                tags += clipLabels.filter { !seen.contains($0.lowercased()) }
            }
            let caption = (await tagStore.captions(forRefKeys: [refKey]))[refKey]
            let hasCaption = caption?.isEmpty == false
            // キャプションは**お気に入り限定**なので、「生成中」は VLM 同梱かつ未生成かつ**お気に入り**のときだけ出す
            // （非お気に入りは今後も付かないので空欄でよい・誤って「生成中」を出さない）。
            let captionPending = !hasCaption && tagTagger.isCaptioningAvailable && favoritesCache.contains(refKey)
            return PhotoInsight(tags: Array(tags.prefix(10)), people: rec.photo.people,
                                caption: hasCaption ? caption : nil,
                                captionPending: captionPending,
                                isScreenshot: rec.photo.isScreenshot,
                                status: status)
        }
        // 付加情報が無い＝まだ取り込まれていない。
        return PhotoInsight(status: .notIndexed)
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
        Task {
            defer { isMakingAIAlbum = false }
            if let id {
                _ = await updateAIAlbum(id: id, title: title, criteria: criteria)
            } else {
                _ = await createAIAlbum(title: title, criteria: criteria)
            }
        }
    }

    public func deleteAIAlbum(id: String) async {
        aiAlbums = await aiService.delete(id: id)
    }

    private func makeAIAlbum(id: String, title: String, criteria: String) async -> AIAlbumResult {
        let (result, albums) = await aiService.make(id: id, title: title, criteria: criteria)
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
    public func scheduleBackgroundFill() {
        let preset = Self.currentBackgroundPreset()
        Task(priority: .background) {
            isTagging = true
            // 表示ラベラの概念埋め込み（約300語）を前倒しで構築する（初回に写真を開いた瞬間の
            // 数秒のフォアグラウンド負荷を夜間へ移す）。
            await labelProvider?.prewarm()
            // P1: まずシーンタグ（Vision・数十ms/枚＝速い）を全量に行き渡らせる。
            // タグは検索の一次ランキングなので、CLIP 埋め込みより先に揃える価値が高い。
            // 候補は**新しい写真から先に**（撮影日降順）＝撮りたての写真が検索へ最速で反映される。
            let candidates = await store.enrichedRefKeysNewestFirst()
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
            // VLM キャプション（重い文章生成）は**お気に入り限定**。最新のお気に入り集合を取り込む
            // （favorite は変化するので毎回の背景実行で更新。新規お気に入りは次回巡回で付く）。
            // 処理順は**撮影日降順**（新しい写真から先に説明が付く）。
            await refreshFavoritesCache()
            let favorites = favoritesCache
            let favoritesOrdered = await store.newestFirst(refKeys: favorites)
            while !BackgroundYield.heavyShouldPause() {
                let embedBefore = await store.unembeddedCount()
                await tagger.embedUnprocessed(batchSize: preset.batchSize,
                                              betweenBatchNs: preset.betweenBatchNs,
                                              maxBatches: 12,
                                              shouldPause: embedPause,
                                              networkAllowed: { NetworkStateMonitor.shared.networkAllowed() },
                                              onProgress: { BackgroundActivityMonitor.shared.embedRemaining = $0 }) {
                    [weak self] newKeys in await self?.refreshAIAlbumsThrottled(newRefKeys: newKeys)
                }
                let embedAfter = await store.unembeddedCount()
                if BackgroundYield.heavyShouldPause() { break }
                let capBefore = await tagStore.captionPendingCount(favorites: favorites)
                await tagTagger.captionUnprocessed(maxBatches: 3, favoritesNewestFirst: favoritesOrdered,
                                                   shouldPause: captionPause)
                let capAfter = await tagStore.captionPendingCount(favorites: favorites)
                // どちらも 1 枚も進まなかった＝残作業なし（お気に入り分のキャプション完了含む）→ 終了。
                let progressed = (embedAfter < embedBefore) || (capAfter < capBefore)
                if !progressed { break }
            }
            isTagging = false
        }
    }

    /// 設定（重さ段階）から現在のバックグラウンド埋め込みプリセットを読む。
    static func currentBackgroundPreset() -> BackgroundProcessingPreset {
        let index = UserDefaults.standard.object(forKey: AutoAlbumSettingsKeys.backgroundProcessingLevel) as? Int
            ?? BackgroundProcessing.defaultIndex
        return BackgroundProcessing.preset(at: index)
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
        let preset = Self.currentBackgroundPreset()
        isTagging = true
        await tagger.embedUnprocessed(batchSize: preset.batchSize,
                                      betweenBatchNs: preset.betweenBatchNs,
                                      shouldPause: { [weak self] in
                                          (self?.isInteracting ?? false) || MemoryPressureMonitor.shared.isUnderPressure
                                      },
                                      onProgress: { BackgroundActivityMonitor.shared.embedRemaining = $0 }) {
            [weak self] newKeys in await self?.refreshAIAlbumsThrottled(newRefKeys: newKeys)
        }
        isTagging = false
    }
}
