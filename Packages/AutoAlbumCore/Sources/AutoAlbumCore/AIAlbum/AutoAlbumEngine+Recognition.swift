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
            // A4 パフォーマンス: タグ等の照会を**並列**で発行する（旧: 直列 await
            // ＝スワイプ連打時のパネル表示遅延）。CLIP 表示ラベルも rec を得た時点で並行に走らせる。
            async let tagsTask = tagStore.tags(forRefKeys: [refKey])
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
            let ocrText = (await ocrTask)[refKey]
            let usage = (await usageTask)[refKey]
            return PhotoInsight(tags: Array(tags.prefix(10)), people: rec.photo.people,
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
    /// 全写真に付与）が**分布適応しきい値**（`PhotoQuality.adaptiveThreshold`＝上位 20% を
    /// [0.2, 0.6] にクランプ）以上、かつスクリーンショットでない。
    /// スコア未付与（解析待ち）の写真は含めない＝解析が進むほど対象が増える。
    public func beautifulPhotoKeys() async -> Set<String> {
        let all = await tagStore.allAesthetics()
        guard !all.isEmpty else {
            Diagnostics.mark("quality: no aesthetic scores yet (tagging pending)")
            return []
        }
        let screenshots = await store.screenshotRefKeys()
        // ⚠️ しきい値の算出・6 万件の filter・集合演算・分位点のソートは**オフメイン**で行う
        // （ADR-85）。以前は @MainActor のここで 62,330 件を回しており、フィルタを ON にするたび
        // メインが 1.4 秒止まっていた（実機ログ diag-33 の唯一の前面ハング）。
        // CLAUDE.md の性能原則「巨大コレクションを MainActor に通さない」の違反だった。
        let (result, summary) = await Task.detached(priority: .userInitiated) {
            () -> (Set<String>, String) in
            let threshold = PhotoQuality.adaptiveThreshold(scores: Array(all.values))
            let good = Set(all.filter { $0.value >= threshold }.keys)
            let result = good.subtracting(screenshots)
            // 実測ログ: 分布（中央値/上位10%/最大）としきい値・件数。しきい値校正の判断材料に残す。
            let sorted = all.values.sorted(by: >)
            let p50 = sorted[sorted.count / 2]
            let p90 = sorted[min(sorted.count - 1, sorted.count / 10)]
            let summary = String(
                format: "quality: scored=%d p50=%.2f p90=%.2f max=%.2f thr=%.2f best=%d (screenshots excluded=%d)",
                all.count, p50, p90, sorted.first ?? 0, threshold,
                result.count, good.count - result.count)
            return (result, summary)
        }.value
        Diagnostics.mark(summary)
        return result
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

    /// 同じ名前の AI アルバムが既にあるか（大小・前後空白を無視。`excluding` は編集中の自分）。
    /// クラウド共有のフォルダ名がアルバム名から決まるため、**同名は作らせない**
    /// （連番フォルダ `◯◯ 2` ができて分かりにくくなる・実フィードバック）。
    public func aiAlbumTitleExists(_ title: String, excluding id: String? = nil) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return aiAlbums.contains {
            $0.id != id && $0.placesLabel.compare(trimmed, options: [.caseInsensitive]) == .orderedSame
        }
    }

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
        // 二重実行の抑止（diagnostics-48: 同一 criteria の make が 2 本並走し、86k フェッチが
        // 直列化されて fetch 20.7 秒 ×2 ＝メイン飢餓 20.5 秒の主因になった）。
        guard !isMakingAIAlbum else {
            Diagnostics.mark("aialbum.make: skip — already making")
            return
        }
        isMakingAIAlbum = true
        // ⚠️ utility にする（diagnostics-48）。userInitiated だと 86k フェッチ・採点の協調タスクが
        // P コアを占有し、メインスレッドが数十秒スケジュールされない（飢餓＝体感は完全なフリーズ）。
        // ユーザーはスピナーで進行を見られるので、応答性を優先する。
        let albumID = id ?? "\(AIAlbumStrategy.strategyID):\(UUID().uuidString)"
        Task(priority: .utility) {
            defer { isMakingAIAlbum = false }
            // 第 1 段: 決定的プレビュー（1〜2 秒でアルバムが現れる・従来どおり）。
            _ = await updateAIAlbum(id: albumID, title: title, criteria: criteria)
            // 第 2 段（ADR-110）: FM 解釈つきの即時本番化。「バレエ」のようなレキシコン外の語も
            // 作成から十数秒で条件化される（従来は夜間まで「人物の全写真」のままだった＝
            // diagnostics-49 の実障害）。ユーザーの明示操作なので夜間ゲートの対象外。
            // 語彙接地だけは重心キャッシュ済みのときのみ（コールドなら夜間が接地込みで再仕上げ）。
            let lite: [EnrichedPhoto]? = {
                guard let snap = suggestionSnapshot,
                      Date().timeIntervalSince(snap.builtAt) < 1800 else { return nil }
                return snap.lite
            }()
            if let refreshed = await aiService.finalizeNow(id: albumID, baseLite: lite) {
                aiAlbums = refreshed
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
        let result = await aiService.refreshIncremental(newRefKeys: pending, current: aiAlbums)
        aiAlbums = result.albums
        // ⚠️ 採点できなかった分は**待機列へ戻す**。戻さないと評価済みにもならず待機列にも
        // 残らないため、追加枚数がドリフト閾値を超えるまでアルバムへ入らない（レビュー指摘）。
        if !result.deferredRefKeys.isEmpty {
            pendingNewEmbeds.append(contentsOf: result.deferredRefKeys)
            Diagnostics.mark("aialbum.incremental: re-queued \(result.deferredRefKeys.count) deferred photo(s)")
        }
    }

    // MARK: - Recognition (Vision/CLIP タグ付け)

    /// 1 回の背景実行でシーンタグに割り当てるバッチ数の上限（ADR-85）。
    /// 8 枚/バッチなので 40 バッチ ≒ 320 枚。これを超えたら打ち切って CLIP 埋め込み・
    /// キャプションへ順番を回す（タグが窓を独占して埋め込みが飢餓するのを防ぐ）。
    /// 次の実行で続きから進むので、総量は変わらず「どれも少しずつ進む」状態になる。
    static var tagBatchesPerRun: Int { 40 }

    /// 背景の重い処理（タグ付け・埋め込み・キャプション）を**明示的に止める**（ADR-79）。
    /// フォアグラウンド復帰で呼ぶ。トリクル各段は `Task.isCancelled` を 1 単位ごとに見るため、
    /// 実行中の 1 枚が終わり次第すぐ抜ける。作業は差分ベースなので次の夜間窓で続きから再開する。
    /// 完了は待たない（復帰時にメインを塞がないため）。
    public func stopBackgroundWork() {
        backgroundFillTask?.cancel()
        backgroundFillTask = nil
        // 表示ラベラの事前ウォーム（約300語の text encode）も止める（ADR-80）。
        // ⚠️ 外側の Task を cancel するだけでは**止まらない**（ADR-95 追記）。ラベラは二重構築を
        //    防ぐため共有 Task に合流する作りで、そこへは伝播しないため、約300語の encode と
        //    CLIP テキストタワーのロード（実機 diagnostics-40 で 15456ms）が走り切って ANE ゲートを
        //    占有し続けていた。中断の意思を seam で明示的に伝える。
        prewarmTask?.cancel()
        prewarmTask = nil
        labelProvider?.cancelPrewarm()
        // 実行中の generate（前面の定期ループから起動されたものを含む）にも降りるよう伝える。
        // generate は呼び出し側のタスク上で走るため cancel では止められない（ADR-79 追記）。
        requestAbortHeavyWork()
    }

    /// 未タグ写真の Vision タグ付け＋AI アルバム再評価をバックグラウンドで進める（非ブロッキング）。
    /// QoS は `.background`：UI 操作（.userInitiated）と CPU を奪い合わず、OS が優先度を下げる。
    /// 未タグ写真の Vision タグ付け＋CLIP 埋め込みをバックグラウンドで進める。
    /// ※ 一時停止で滞留したタスクは、ゲートが開けば（`heavyShouldPause` が false になれば）内部の
    ///   `waitWhilePaused` で**自分で再開**する。生成フラグ滞留の安全弁は
    ///   `BackgroundActivityMonitor.isGeneratingAlbums`（時間失効）とデバッグ全開バイパスが担う。
    /// 実行中の背景処理を**明け渡させてから**開始し直す。夜間 BGTask 窓の先頭でだけ使う（ADR-95）。
    ///
    /// BGTask 窓は重い処理のための特権時間で、実測では 77 秒しか無いこともある。そこへ
    /// 「前面起動時に始まってゲート閉で眠っている bgfill」が実行中フラグを握ったままだと、
    /// 窓は `bgfill: skip — already tagging/embedding` だけを残して丸ごと空転する
    ///（実機 diagnostics-38: 窓 77 秒のうち有効な処理は 0）。滞留側を降ろして窓を使い切る。
    /// 各処理は差分ベースかつバッチごとに保存しているので、割り込んでも取りこぼさない。
    public func restartBackgroundFill() {
        if isTagging {
            Diagnostics.mark("bgfill: preempting the in-flight run for the background window")
            fillGeneration &+= 1        // 旧タスクの末尾処理を無効化（世代ガード）
            backgroundFillTask?.cancel()
            backgroundFillTask = nil
            isTagging = false
        }
        scheduleBackgroundFill()
    }

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
        fillGeneration &+= 1
        let generation = fillGeneration
        let preset = Self.currentBackgroundPreset()
        backgroundFillTask = Task(priority: .background) {
            // 世代ガード: `restartBackgroundFill` で明け渡した旧タスクが遅れて末尾に来ても、
            // 後続タスクの実行中フラグ／ハンドルを踏まない（ADR-95）。
            defer {
                if fillGeneration == generation {
                    isTagging = false
                    backgroundFillTask = nil
                }
            }
            Diagnostics.mark("bgfill: begin (pause=\(BackgroundYield.heavyShouldPause()) "
                             + "generating=\(BackgroundActivityMonitor.shared.isGeneratingAlbums))")
            // ⚠️ **準備の前にゲートを待つ**（ADR-95 追記）。この下の準備——お気に入り再取得・
            //    全解析対象キーの取得（約 86k）・`AnalysisOrder.ordered` の並べ替え——は数秒かかる。
            //    以前はゲート判定より先に走っており、`bgfill: begin (pause=true)` から
            //    `tags: start` まで実機で 5〜8 秒、その間にメインが 2.0〜3.2 秒ブロックしていた
            //    （diagnostics-39・起動時と前面復帰時の残ハングの正体）。しかも直後に
            //    `tags: finished — 0 tagged` で捨てられる＝**やる気が無いときに準備だけしていた**。
            //    待ちは 60 秒で打ち切られ、フラグを解放して抜ける（居座らない）。
            if await BackgroundTrickle.waitWhilePaused({ BackgroundYield.heavyShouldPause() }) {
                Diagnostics.mark("bgfill: gate stayed closed — standing down")
                return
            }
            guard !Task.isCancelled else { return }
            // 表示ラベラの概念埋め込み（約300語）は**別タスクで前もって温める**（fire-and-forget）。
            // ANE 直列化ゲートは encodeText の内側で**1 語ずつ**取る（ADR-73）。ここでまとめて包むと
            // 約300語ぶんゲートを握り続け、その間の顔スキャン・タグ付けが完全に止まる。
            //
            // ⚠️ ゲートが閉じているときは**起動しない**（ADR-80）。以前はゲート判定の外にあったため、
            // 起動直後（pause=true）でも CLIP テキストタワーのロード（新規インストール直後は
            // 実測 23 秒）＋約300語の encode が走り、起動を重くしていた。未ウォームでも実害はない
            // ——`isReady` が false のとき insight は CLIP ラベルを飛ばし Vision タグだけで即返す。
            if !BackgroundYield.heavyShouldPause() {
                prewarmTask = Task(priority: .background) { [weak self] in
                    guard let self, let labeler = self.labelProvider else { return }
                    await labeler.prewarm()
                    self.prewarmTask = nil
                }
            }
            // お気に入り集合を先に取り込み、全解析の**処理順（お気に入り優先）**に使う（変化するので毎回更新）。
            await refreshFavoritesCache()
            let favorites = favoritesCache
            // P1: まずシーンタグ（Vision・数十ms/枚＝速い）を進める。
            // タグは検索の一次ランキングなので、CLIP 埋め込みより先に揃える価値が高い。
            // 候補は **お気に入り(ローカル→クラウド)→その他(ローカル→クラウド)・各新→古**（AnalysisOrder）。
            // クラウド写真のタグ付けはサムネDLを要するため、回線NG（Wi-Fi 待ち等）なら今回はローカルのみ
            // （Wi-Fi 復帰後の次回にクラウド分を拾う）。ローカルは通信不要なので常に進む（Fix B）。
            //
            // ⚠️ **1 回の実行あたりの上限を設ける**（ADR-85）。上限なしだとタグが全量終わるまで
            //    下の埋め込みループに到達せず、CLIP 埋め込みが**永久に飢餓**する。実測（実機ログ
            //    diag-28〜33）でタグは 33,662→24,505 と進む一方、未埋め込みは 43,611→43,626 と
            //    まったく減らず、`embed: batch` が数週間 1 度も出ていなかった。夜間の窓は数分〜
            //    数十分で、その間ずっとタグが窓を使い切っていたため。ADR-72 の「バックアップが
            //    埋め込みに飢餓する」と同じ構造で、対処も同じ＝**順番を必ず回す**。
            let tagNetOK = NetworkStateMonitor.shared.networkAllowed()
            let tagPool = await store.enrichedRefKeysNewestFirst()
            // ⚠️ 絞り込みと並べ替えは**メインから降ろす**（ADR-95 追記）。`AnalysisOrder.ordered` は
            //    約 86k 件の安定ソート（比較ごとに Set 参照）で、MainActor で回すと数百ms〜秒級に
            //    なる（CLAUDE.md 性能原則 4）。純ロジックなので detached で計算し、結果だけ受け取る。
            let candidates = await Task.detached(priority: .background) {
                AnalysisOrder.ordered(tagNetOK ? tagPool : tagPool.filter { $0.hasPrefix("L-") },
                                      favorites: favorites)
            }.value
            await tagTagger.tagUnprocessed(candidateRefKeys: candidates,
                                           maxBatches: Self.tagBatchesPerRun,
                                           shouldPause: { BackgroundYield.heavyShouldPause() })
            // ⚠️ フェーズの切れ目で**キャンセルを見る**（ADR-95）。フォアグラウンド復帰の
            //    `stopForForeground()` はこのタスクを cancel するが、以前は次フェーズへそのまま進み、
            //    「embed loop entry (unembedded=40181)」→「embed: finished — 0 photos in 0.0s」という
            //    実態と食い違うログだけを残していた（実機 diagnostics-38）。トリクル本体が先頭で
            //    キャンセルを見て即 return するため、作業はゼロなのに着手したように見えていた。
            guard !Task.isCancelled else {
                Diagnostics.mark("bgfill: cancelled after tag phase")
                return
            }
            // P2: CLIP 埋め込みを進捗しなくなるまで回す（VLM キャプションのインターリーブは
            // 廃止＝ADR-108。窓はすべて埋め込み・タグ・顔スキャンに使う）。
            let embedPause: @MainActor () -> Bool = { [weak self] in
                // 重い処理の共通方針（電源接続＋低電力OFF＋一定時間アイドル＋生成との相互排他）は
                // BackgroundYield.heavyShouldPause に一元化。埋め込みは操作中も譲る。
                (self?.isInteracting ?? false) || BackgroundYield.heavyShouldPause()
            }
            Diagnostics.mark("bgfill: embed loop entry (pause=\(BackgroundYield.heavyShouldPause()) "
                             + "generating=\(BackgroundActivityMonitor.shared.isGeneratingAlbums) "
                             + "unembedded=\(await store.unembeddedCount()))")
            while !BackgroundYield.heavyShouldPause(), !Task.isCancelled {
                let embed = await runEmbedPhase(preset: preset, favorites: favorites,
                                                shouldPause: embedPause)
                // 1 枚も進まなかった＝残作業なし → 終了。
                if embed.after >= embed.before { break }
            }
            // isTagging は先頭の defer で必ず戻す（二重起動抑止と対）。
        }
    }

    /// CLIP 埋め込みフェーズ。戻り値は実行前後の未埋め込み件数（進捗判定用）。
    private func runEmbedPhase(preset: BackgroundProcessingPreset,
                               favorites: Set<String>,
                               shouldPause: @escaping @MainActor () -> Bool) async -> (before: Int, after: Int) {
        let before = await store.unembeddedCount()
        await tagger.embedUnprocessed(batchSize: preset.batchSize,
                                      betweenBatchNs: preset.betweenBatchNs,
                                      maxBatches: 12,
                                      favorites: favorites,
                                      shouldPause: shouldPause,
                                      networkAllowed: { NetworkStateMonitor.shared.networkAllowed() },
                                      onProgress: { BackgroundActivityMonitor.shared.embedRemaining = $0 }) {
            [weak self] newKeys in await self?.refreshAIAlbumsThrottled(newRefKeys: newKeys)
        }
        return (before, await store.unembeddedCount())
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

    /// 画像解析の進捗スナップショット（ユーザー向け「AI 解析の状況」画面用）。
    /// `total`（取り込み済み写真数＝分母）と、各パスの完了数を 1 回で取得する。
    /// 完了時刻は `AnalysisActivity.lastActivity(_:)` で別途読む（UserDefaults・同期）。
    public func analysisProgress() async -> AnalysisProgress {
        async let total = store.enrichmentCount()
        async let embedded = store.embeddedCount()
        // ⚠️ タグの分子は**分母と同じ列挙（台帳の refKey）**から数える。タグ台帳は別コンテナで、
        // 削除・移動した写真の記録が残るため、記録の総数を分子にすると 100% を超えた
        // （実機: 86,821 枚中 88,184）。ピープルの「残り」と同じ形の誤り。
        let keys = await store.enrichedRefKeysNewestFirst()
        let tagged = await tagStore.taggedCount(among: keys)
        return AnalysisProgress(total: await total, embedded: await embedded,
                                sceneTagged: tagged)
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
