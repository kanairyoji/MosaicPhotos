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
        for refKey in Self.candidateRefKeys(for: id) {
            guard let rec = await store.insightRecord(refKey: refKey) else { continue }
            let status: PhotoInsight.Status = rec.tagged ? .ready : .analyzing
            // 表示専用タグ：保存済み CLIP ベクトルに対するゼロショット（検索は語彙ゼロのまま）。
            var tags: [String] = []
            if let vector = rec.photo.clipVector, let labelProvider {
                tags = await labelProvider.labels(forEmbedding: vector)
            }
            return PhotoInsight(tags: tags, people: rec.photo.people, status: status)
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

    /// T5: 埋め込み進行に伴う再評価の**時間スロットル**。48 バッチごとの onBatch でも 1 回の
    /// 再評価はベクトル約 13MB のページ読み＋採点を伴い、残 72k の消化中に累計 ~1.2GB の
    /// ディスク読みになる。前回から 5 分未満かつ残作業ありならスキップ（完了時は必ず反映）。
    func refreshAIAlbumsThrottled() async {
        let remaining = BackgroundActivityMonitor.shared.embedRemaining
        if remaining > 0, Date().timeIntervalSince(lastAIRefreshAt) < 300 { return }
        lastAIRefreshAt = Date()
        await refreshAIAlbums()
    }

    // MARK: - Recognition (Vision/CLIP タグ付け)

    /// 未タグ写真の Vision タグ付け＋AI アルバム再評価をバックグラウンドで進める（非ブロッキング）。
    /// QoS は `.background`：UI 操作（.userInitiated）と CPU を奪い合わず、OS が優先度を下げる。
    public func scheduleBackgroundFill() {
        let preset = Self.currentBackgroundPreset()
        Task(priority: .background) {
            isTagging = true
            await tagger.embedUnprocessed(batchSize: preset.batchSize,
                                          betweenBatchNs: preset.betweenBatchNs,
                                          shouldPause: { [weak self] in
                                          // 重い処理の共通方針（電源接続＋低電力OFF＋一定時間アイドル＋
                                          // 生成との相互排他）は BackgroundYield.heavyShouldPause に一元化。
                                          (self?.isInteracting ?? false)
                                              || BackgroundYield.heavyShouldPause()
                                      },
                                          networkAllowed: { NetworkStateMonitor.shared.networkAllowed() },
                                          onProgress: { BackgroundActivityMonitor.shared.embedRemaining = $0 }) {
                [weak self] in await self?.refreshAIAlbumsThrottled()
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

    /// 埋め込み済み／未処理の写真数（設定画面の進捗表示用）。
    public func recognitionCounts() async -> (tagged: Int, untagged: Int) {
        async let tagged = store.embeddedCount()
        async let untagged = store.unembeddedCount()
        return (await tagged, await untagged)
    }

    /// 全写真の認識結果（CLIP 埋め込み・キャプション）を消去し、最新ロジックで一から付け直す。
    /// 「再解析」用。完了まで await する（UI はスピナー表示）。
    public func reanalyzePhotos() async {
        guard !isTagging else { return }
        await store.clearPerception()
        let preset = Self.currentBackgroundPreset()
        isTagging = true
        await tagger.embedUnprocessed(batchSize: preset.batchSize,
                                      betweenBatchNs: preset.betweenBatchNs,
                                      shouldPause: { [weak self] in
                                          (self?.isInteracting ?? false) || MemoryPressureMonitor.shared.isUnderPressure
                                      },
                                      onProgress: { BackgroundActivityMonitor.shared.embedRemaining = $0 }) {
            [weak self] in await self?.refreshAIAlbumsThrottled()
        }
        isTagging = false
    }
}
