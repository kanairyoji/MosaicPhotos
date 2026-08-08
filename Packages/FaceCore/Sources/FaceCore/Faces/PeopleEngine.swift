import PerceptionCore
import Foundation
import MosaicSupport
import Observation

/// ピープル（顔クラスタ）のファサード。`FaceStore`（永続）と `FaceTagger`（背景スキャン）を束ね、
/// 表示用の `people: [PersonInfo]` を提供する。CLIP の `AutoAlbumEngine` に相当する People 版。
/// 顔の検出/埋め込み実体は `FacePerceptionProvider`（アプリ側＝Vision+CoreML）を注入する。
@MainActor
@Observable
public final class PeopleEngine {
    public private(set) var people: [PersonInfo] = []
    public private(set) var isLoaded = false
    public private(set) var isScanning = false
    /// 未スキャン残り枚数（おおよそ）。
    public private(set) var remaining = 0

    @ObservationIgnored private let store: FaceStore
    @ObservationIgnored private let tagger: FaceTagger
    @ObservationIgnored private let faceProvider: FacePerceptionProvider?
    /// お気に入り写真の refKey 集合（"L-…"）を返す seam（アプリ側＝PhotoKit が実装）。
    /// 代表写真の自動選択で「お気に入りの写真を優先」するために使う。nil なら優先なし。
    @ObservationIgnored private let favoriteRefKeysProvider: (() async -> Set<String>)?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// スキャンの世代。`stopScan` / `startScan` で進み、末尾処理は「自分の世代のときだけ」
    /// ハンドルと進捗フラグを片付ける（止めた直後に始まった新スキャンを踏まないため）。
    @ObservationIgnored private var scanGeneration = 0
    /// 直近のスキャン候補（reset 後の再スキャンに使う）。
    @ObservationIgnored private var lastCandidates: [String] = []
    @ObservationIgnored private var lastAllowSimulator = false

    /// 「人物」として扱う最小の写真枚数（レビュー・検索・名前解決の母数）。
    /// 少ない断片も統合の対象にはしたいので、ここは低めに保つ。
    private let minFaces = 3
    /// **ホームのピープル列に出す**最小枚数（ADR-68 追補5）。
    /// 「5 枚以内の人は重要人物ではない」＝ **6 枚以上**をトップに出す（実フィードバック）。
    /// 数枚しか写っていない人はトップに並べる価値が薄く、成長期の断片も混ざって列が埋まる。
    /// 「すべて表示」では `minFaces`（3 枚以上）の全員を出すので、埋もれて見えなくなることはない。
    public static let minFacesForCarousel = 6

    /// ホームのピープル列に出す人物（枚数の多い順）。
    public var prominentPeople: [PersonInfo] {
        people.filter { $0.count >= Self.minFacesForCarousel }
    }

    /// FaceStore は internal のため注入はこの init（internal）経由。外部（アプリ）は
    /// `makeWithOffMainStore` を使う。
    init(faceProvider: FacePerceptionProvider?,
         favoriteRefKeysProvider: (() async -> Set<String>)? = nil,
         store: FaceStore? = nil) {
        let store = store ?? FaceStore()
        self.store = store
        self.faceProvider = faceProvider
        self.favoriteRefKeysProvider = favoriteRefKeysProvider
        self.tagger = FaceTagger(store: store, provider: faceProvider)
    }

    /// 本番用ファクトリ。⚠️ @ModelActor（FaceStore）は「init したスレッド」で実行されるため、
    /// **オフメインで生成**してから組み立てる（MainActor 直 init だと顔スキャンの SwiftData が
    /// 全部メインスレッドで走る — AutoAlbumStore で実測 14.5s ハングになった同じ罠）。
    public static func makeWithOffMainStore(
        faceProvider: FacePerceptionProvider?,
        favoriteRefKeysProvider: (() async -> Set<String>)? = nil
    ) async -> PeopleEngine {
        // 起動背景の SwiftData 初期化（ユーザーが直接待つ処理ではない）＝ .utility へ（提案2）。
        let store = await Task.detached(priority: .utility) { FaceStore() }.value
        return PeopleEngine(faceProvider: faceProvider,
                            favoriteRefKeysProvider: favoriteRefKeysProvider,
                            store: store)
    }

    /// 顔モデルが同梱され利用可能か（未同梱ならピープルは無効＝空表示）。
    public var isFaceModelAvailable: Bool { faceProvider?.isAvailable ?? false }

    /// 永続済みのクラスタからピープル一覧を読み込む。
    /// 代表写真はユーザー選択（保存済み）→ お気に入り写真 → 認識した写真の先頭、の順で決まる。
    public func loadPeople() async {
        await store.apply(tuning: tuning)   // 冪等（変更が無ければ何もしない・ADR-70）
        let favorites = await favoriteRefKeysProvider?() ?? []
        people = await store.peopleClusters(minFaces: minFaces, favoriteRefKeys: favorites)
        isLoaded = true
        Diagnostics.mark("faces: people=\(people.count) (>= \(minFaces) faces, favs=\(favorites.count))")
    }

    /// 端末写真の refKey 候補（"L-…"）の未スキャン分を背景で処理する。重複起動は防ぐ。
    /// `allowSimulator` が true なら（Developer Options のデバッグトグル）シミュレータでも走らせる。
    /// ※ 一時停止で滞留した既存スキャンは、ゲートが開けば（`BackgroundYield.heavyShouldPause` が
    ///   false になれば）**自分で再開**するので、force のような再生成は行わない（旧実装の await 詰まり
    ///   を撤去）。生成フラグ滞留の安全弁は `BackgroundActivityMonitor.isGeneratingAlbums`（時間失効）と
    ///   デバッグ全開時の相互排他バイパスが担う。
    /// 進行中の顔スキャンを**明示的に止める**（ADR-79）。フォアグラウンド復帰で呼ぶ。
    /// `FaceTagger` のトリクルは 1 枚ごとに `Task.isCancelled` を見るため、実行中の 1 枚が
    /// 終わり次第すぐ抜ける。スキャンは差分（未処理 refKey）ベースなので次窓で続きから再開する。
    /// `reset(includingCorrections:)` と違い**完了を待たない**（復帰時にメインを塞がないため）。
    public func stopScan() {
        guard scanTask != nil else { return }
        scanTask?.cancel()
        scanTask = nil
        // 世代を進める＝止めた側のタスクが遅れて末尾処理に来ても、後続スキャンの
        // ハンドル/フラグを踏まないようにする（二重起動の防止）。
        // 進捗フラグは**ここで**畳む（世代ガードにより旧タスクの末尾処理は素通りするため）。
        scanGeneration &+= 1
        isScanning = false
        BackgroundActivityMonitor.shared.isScanningFaces = false
        BackgroundActivityMonitor.shared.faceScanRemaining = 0
        Diagnostics.mark("faces: stopScan (foreground return)")
    }

    public func startScan(candidateRefKeys: [String], allowSimulator: Bool = false) {
        // 診断: startScan がなぜ走らない/走るのかを可視化する（実機で faces:start が一切出ない事例の切り分け）。
        guard isFaceModelAvailable else {
            Diagnostics.mark("faces: startScan skip — model unavailable "
                             + "(provider=\(faceProvider != nil ? "yes" : "nil") "
                             + "available=\(faceProvider?.isAvailable ?? false))")
            isLoaded = true
            return
        }
        lastCandidates = candidateRefKeys
        lastAllowSimulator = allowSimulator
        // 一時停止で滞留したスキャンは、ゲートが開けば（heavyShouldPause=false）内部の waitWhilePaused で
        // 自分で再開する（旧: force による差し替えは isRunning レースで詰まったため撤去）。真因の画像ロード
        // ハング（PHAssetImageLoader）は別途修正済みなので、再開後は正常に検出まで進む。
        guard scanTask == nil else {
            Diagnostics.mark("faces: startScan skip — already running (resumes when gate opens)")
            return
        }
        Diagnostics.mark("faces: startScan → begin (candidates=\(candidateRefKeys.count) allowSim=\(allowSimulator))")
        scanGeneration &+= 1
        let generation = scanGeneration
        scanTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            self.isScanning = true
            BackgroundActivityMonitor.shared.isScanningFaces = true
            await self.store.apply(tuning: self.tuning)   // スキャン前に必ず適用（ADR-70）
            // 版上げ（埋め込みパイプライン変更＝ADR-51）なら全再スキャンへ移行する
            //（命名は写真の重なりで持ち越し・修正ジャーナルは残す）。
            await self.migrateScanVersionIfNeeded()
            await self.tagger.scan(
                candidateRefKeys: candidateRefKeys,
                allowSimulator: allowSimulator,
                shouldPause: {
                    // 重い処理の共通方針（電源接続＋低電力OFF＋一定時間アイドル＋生成との
                    // 相互排他）は BackgroundYield.heavyShouldPause に一元化。端末内写真の顔検出は
                    // 通信不要なので Wi-Fi は要求しない（ローカルゲート）。
                    BackgroundYield.heavyShouldPause()
                },
                networkAllowed: {
                    // クラウド写真の顔検出はキャッシュ済みサムネDLを要するため回線ポリシーに従う。
                    NetworkStateMonitor.shared.networkAllowed()
                },
                onProgress: {
                    self.remaining = $0
                    BackgroundActivityMonitor.shared.faceScanRemaining = $0
                },
                onBatch: { [weak self] in await self?.loadPeople() })
            // B2: スキャン完了後、修正が増えていれば制約付き再クラスタリングで全体を最適化
            //（夜間ウィンドウ内・数秒・順序依存の誤りを解消する）。
            // 版上げ再スキャン中なら、進んだ分だけ名前を段階的に戻す（数晩に分かれても可）。
            await self.reapplyCarryoverNames()
            if !BackgroundYield.heavyShouldPause() {
                await self.rebuildClustersIfNeeded()
            }
            // 自分の世代のときだけ片付ける（stopScan 後に始まった新スキャンを踏まない）。
            guard self.scanGeneration == generation else { return }
            self.isScanning = false
            BackgroundActivityMonitor.shared.isScanningFaces = false
            BackgroundActivityMonitor.shared.faceScanRemaining = 0
            self.scanTask = nil
        }
    }

    // MARK: - スキャン版数（埋め込みパイプラインの版・ADR-51）

    /// 顔スキャンパイプラインの現行版。v2: 顔アライメント（目の位置正規化）＋処理解像度
    /// 640→1024px。v3: EXIF 回転の正規化（HEIC 等の未回転ビットマップで顔矩形・埋め込みが
    /// ズレていた写真の作り直し）。v4: マルチクロップ埋め込み平均（ADR-54）。
    /// **埋め込みの作り方が変わる版上げでは新旧の埋め込みを混在させられない**
    /// （コサイン類似度が壊れる）ため、全再スキャンする。
    public static let faceScanVersion = 4
    private static let faceScanVersionKey = "faceScanVersion"

    /// 実効パイプライン版。**同梱モデル（provider）が宣言**した版を優先する（ADR-70）。
    /// モデルを差し替えたら face_config.json の pipelineVersion が上がり、全再スキャンが走る。
    public var effectiveScanVersion: Int { faceProvider?.pipelineVersion ?? Self.faceScanVersion }

    /// 類似度スケール依存の定数一式（ADR-70・provider＝同梱モデルが宣言）。
    var tuning: FaceTuning { faceProvider?.tuning ?? .facenet }

    /// 版が上がっていたら、命名スナップショットを取ってから全消去→再スキャンに移行する。
    /// 修正ジャーナル（FaceCorrection）は残す（負例・校正はモデル不変のため引き続き有効）。
    private func migrateScanVersionIfNeeded() async {
        let stored = UserDefaults.standard.integer(forKey: Self.faceScanVersionKey)
        let current = effectiveScanVersion
        guard stored < current else { return }
        if await store.scannedCount() > 0 {
            let snapshot = await store.namedClusterEntries()
            if !snapshot.isEmpty { saveCarryover(NameCarryover(savedAt: Date(), entries:
                snapshot.map { .init(name: $0.name, memberRefKeys: $0.memberRefKeys) })) }
            await store.reset()
            Diagnostics.mark("faces: scan pipeline v\(stored == 0 ? 1 : stored)→v\(current) "
                             + "— full rescan (carrying \(snapshot.count) names)")
            await loadPeople()
        }
        UserDefaults.standard.set(current, forKey: Self.faceScanVersionKey)
    }

    /// 持ち越し名の再適用（スキャンセッションの末尾で呼ぶ）。全件消化したらファイルを消す。
    private func reapplyCarryoverNames() async {
        guard var carryover = loadCarryover() else { return }
        // 90 日消化されない残り（写真削除等で照合不能）は破棄する。
        if Date().timeIntervalSince(carryover.savedAt) > 90 * 86_400 {
            saveCarryover(nil)
            return
        }
        let before = carryover.entries.count
        let remaining = await store.reapplyNames(carryover.entries.map { ($0.name, $0.memberRefKeys) })
        guard remaining.count != before else { return }
        Diagnostics.mark("faces: carryover names applied \(before - remaining.count)/\(before)")
        carryover.entries = remaining.map { .init(name: $0.name, memberRefKeys: $0.memberRefKeys) }
        saveCarryover(carryover.entries.isEmpty ? nil : carryover)
        await loadPeople()
    }

    /// 名前持ち越しの永続化（Application Support・再起動/数晩に跨る再スキャンに耐える）。
    private struct NameCarryover: Codable {
        var savedAt: Date
        var entries: [Entry]
        struct Entry: Codable {
            var name: String
            var memberRefKeys: [String]
        }
    }

    private var carryoverURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("face-name-carryover.json")
    }

    private func loadCarryover() -> NameCarryover? {
        guard let data = try? Data(contentsOf: carryoverURL) else { return nil }
        return try? JSONDecoder().decode(NameCarryover.self, from: data)
    }

    private func saveCarryover(_ carryover: NameCarryover?) {
        guard let carryover else {
            try? FileManager.default.removeItem(at: carryoverURL)
            return
        }
        if let data = try? JSONEncoder().encode(carryover) {
            try? data.write(to: carryoverURL, options: .atomic)
        }
    }

    /// クラスタに名前を付ける／消す。
    public func rename(clusterID: Int, name: String?) async {
        await store.rename(clusterID: clusterID, name: name)
        await loadPeople()
    }

    /// 人物 src を人物 dst に統合する（同一人物が別々に認識されたときの修正）。
    /// src の顔は全て dst へ移り、src は消える。名前・代表写真は dst を優先。
    /// 2 階層束ね（ADR-61）: 複数の人物を「同じ人（子供の成長で分裂）」として束ねる。
    /// **融合しない**＝各クラスタの純度と時期の分かれを保ったまま 1 人物として表示・検索する。
    /// 後で `unlinkPerson` で解除できる。
    public func linkPeople(_ clusterIDs: [Int]) async {
        await store.linkClusters(clusterIDs)
        await loadPeople()
    }

    /// 束ねから 1 クラスタを外す（別人だった等）。
    public func unlinkPerson(clusterID: Int) async {
        await store.unlinkCluster(clusterID)
        await loadPeople()
    }

    /// この人物の束ねを全解除する（束ねられた全クラスタを単独に戻す）。
    public func ungroupPerson(clusterID: Int) async {
        for id in await store.linkedClusterIDs(primary: clusterID) {
            await store.unlinkCluster(id)
        }
        await loadPeople()
    }

    public func mergePerson(from srcClusterID: Int, into dstClusterID: Int) async {
        await store.mergeClusters(from: srcClusterID, into: dstClusterID)
        await loadPeople()
    }

    /// 写真（`PhotoItem.id`：生 localIdentifier か "L-…" refKey）に写っている人物の表示名。
    /// フル画像ビューの People 表示に使う。顔スキャンは端末写真のみなのでクラウドは空。
    public func names(forItemID id: String) async -> [String] {
        var candidates: [String] = []
        if PhotoRef.decode(id) != nil { candidates.append(id) }
        candidates.append(PhotoRef.local(id).encoded)
        for key in candidates {
            let names = await store.peopleNames(refKey: key, minFaces: minFaces)
            if !names.isEmpty { return names }
        }
        return []
    }

    /// 写真（`PhotoItem.id`：生 localIdentifier か "L-…" refKey）に写っている顔の数（実測）。
    /// フル画像ビューの表示用。未スキャン（クラウド含む）は nil＝「まだ数えていない」。
    public func faceCount(forItemID id: String) async -> Int? {
        var candidates: [String] = []
        if PhotoRef.decode(id) != nil { candidates.append(id) }
        candidates.append(PhotoRef.local(id).encoded)
        for key in candidates {
            if let n = await store.faceCount(refKey: key) { return n }
        }
        return nil
    }

    /// 全スキャン済み写真の refKey → 人物表示名（自動アルバム生成の people 付与＝PeopleProvider 用）。
    public func peopleNamesByRefKey() async -> [String: [String]] {
        await store.peopleNamesByRefKey(minFaces: minFaces)
    }

    /// 名前を付けた人物のフルネーム一覧（"Person N" の未命名は除く）。
    /// AI アルバムの人物名検索の接地カタログに使う。`people` は @Observable なので最新読み込み後に呼ぶ。
    public func namedClusterNames() -> [String] {
        people.compactMap { $0.name }.filter { !$0.isEmpty }
    }

    /// スキャン済み写真の refKey → 顔数（実測）。AI アルバムの「人が写っていない」条件に使う
    /// （AutoAlbumEngine.setFaceCountsProvider へ Composition Root が結線する）。
    public func scannedFaceCounts() async -> [String: Int] {
        await store.scannedFaceCounts()
    }

    /// 顔スキャンの進捗統計（ユーザー向け「AI 解析の状況」画面用）。
    /// `scanned`＝スキャン済み写真数、`faces`＝検出顔総数。件数取得のみで軽い（辞書は返さない）。
    public func scanStats() async -> (scanned: Int, faces: Int) {
        async let scanned = store.scannedCount()
        async let faces = store.faceCount()
        return (await scanned, await faces)
    }

    /// 写真（`PhotoItem.id`：refKey か生 ID）に写る**この人物の**顔矩形（全画面のハイライト用）。
    public func faceHighlights(forItemID id: String, clusterID: Int) async -> [CGRect] {
        var candidates: [String] = []
        if PhotoRef.decode(id) != nil { candidates.append(id) }
        candidates.append(PhotoRef.local(id).encoded)
        candidates.append(PhotoRef.cloud(id).encoded)
        for key in candidates {
            let boxes = await store.faceBoxes(refKey: key, clusterID: clusterID)
            if !boxes.isEmpty { return boxes }
        }
        return []
    }

    /// 代表写真の選択候補（クラスタ内の顔・写真ごと）。
    public func coverCandidates(clusterID: Int) async -> [PersonInfo.Face] {
        await store.facesForCluster(clusterID: clusterID)
    }

    /// 代表写真（トップに出す顔）を選ぶ。
    public func setCover(clusterID: Int, faceID: String) async {
        await store.setCover(clusterID: clusterID, faceID: faceID)
        await loadPeople()
    }

    /// 顔を別の人物へ付け替える（「この人は別の人」）。`toClusterID` が nil なら新規人物。
    public func reassignFace(faceID: String, toClusterID: Int?) async {
        await store.reassignFace(faceID: faceID, toClusterID: toClusterID)
        await loadPeople()
    }

    /// 全消去して再スキャンする（直近の候補があれば自動で再開）。
    /// 修正ジャーナル（負例＝ADR-45）は**残す**ので、再スキャンでも既知の誤りは再発しない。
    public func reset() async {
        await reset(includingCorrections: false)
    }

    /// `includingCorrections` が true なら修正の学習（負例エグゼンプラ）も消す
    /// （Developer Options の「学習もリセット」用）。通常の再スキャンは false。
    public func reset(includingCorrections: Bool) async {
        // 進行中スキャンを止め、**完了を待ってから**ストアを消す（FaceTagger.isRunning のクリアと
        // ストア書き込みの停止を保証。待たずに再スキャンすると isRunning が残って無言 skip する）。
        let running = scanTask
        running?.cancel()
        scanTask = nil
        await running?.value
        if includingCorrections {
            await store.resetIncludingCorrections()
        } else {
            await store.reset()
        }
        await loadPeople()
        Diagnostics.mark("faces: reset(corrections=\(includingCorrections)) — rescanning \(lastCandidates.count) candidates")
        if !lastCandidates.isEmpty {
            startScan(candidateRefKeys: lastCandidates, allowSimulator: lastAllowSimulator)
        }
    }

    /// 修正ジャーナルの件数（Developer Options の診断表示用・ADR-45）。
    public func correctionCount() async -> Int {
        await store.correctionCount()
    }

    // MARK: - 人物レビュー（A1/A2・ADR-46）

    /// レビューカード（「同じ人物？」「この写真は◯◯さん？」）を生成する。
    /// 判断が割れるケースだけを選ぶアクティブラーニング＝1 回答あたりの精度改善を最大化。
    /// ⚠️ 所要は `people.reviewItems` として計測する。生成はクラスタ数ぶんの fetch ＋ 重心の総当たり
    /// 比較で、しかも顔スキャンと**同じ `@ModelActor`** 上で走るため、スキャン中は書き込みの後ろに
    /// 並んで待たされる。「Finding faces to review…」が長い場合の切り分けに使う。
    public func reviewItems(limit: Int = 30) async -> [FaceReviewItem] {
        await PerfTrace.measureAsync("people.reviewItems") {
            await store.reviewItems(minFaces: minFaces, limit: limit,
                                    excluding: overexposedReviewIDs())
        }
    }

    /// カードを実際に表示したら呼ぶ（スキップ検知）。`reviewShownLimit` 回見せても
    /// 答えられなかったカードは以後出題せず、別の質問（次点候補）に切り替える。
    public func noteReviewShown(itemID: String) {
        var counts = (UserDefaults.standard.dictionary(forKey: Self.reviewShownKey) as? [String: Int]) ?? [:]
        counts[itemID, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: Self.reviewShownKey)
    }

    /// 既定回数以上見せたのに未回答のカード ID（＝もう聞かない）。
    private func overexposedReviewIDs() -> Set<String> {
        let counts = (UserDefaults.standard.dictionary(forKey: Self.reviewShownKey) as? [String: Int]) ?? [:]
        return Set(counts.filter { $0.value >= Self.reviewShownLimit }.keys)
    }

    private static let reviewShownKey = "faceReviewShownCounts"
    private static let reviewShownLimit = 3

    /// 「同じ人物ですか？」への回答（A1）。
    /// はい → 統合（正例として学習）。いいえ → 「別人」記録（負例・以後提案しない）。
    public func answerSamePerson(aClusterID: Int, bClusterID: Int, same: Bool) async {
        if same {
            await store.mergeClusters(from: bClusterID, into: aClusterID)
        } else {
            await store.markNotSamePerson(clusterA: aClusterID, clusterB: bClusterID)
        }
        await loadPeople()
    }

    // MARK: - 品質スナップショット（ADR-68）

    /// 実機ライブラリの認識品質を測る（正解ラベル無しで測れる代理指標）。
    /// Developer Options の表示と、診断ログへの記録に使う。
    public func qualityReport() async -> FaceQualityReport {
        await store.qualityReport(minFaces: minFaces)
    }

    /// 品質スナップショットを診断ログへ 1 行記録する（実機で Mac 無しに追える）。
    @discardableResult
    public func logQualityReport() async -> FaceQualityReport {
        let report = await qualityReport()
        Diagnostics.mark(report.logLine)
        // 検出ゲートの棄却内訳も併記する（「顔が取りこぼされている」の切り分け用・ADR-68 追補2）。
        // 起動後のスキャン分のみの集計（プロセス内カウンタ）。
        let detect = FaceDetectionStats.snapshot()
        if detect.candidates > 0 { Diagnostics.mark(detect.logLine) }
        return report
    }

    /// 検出ゲートの棄却内訳（Developer Options 表示用）。
    public nonisolated func detectionStats() -> FaceDetectionStats.Snapshot {
        FaceDetectionStats.snapshot()
    }

    // MARK: - 一括レビュー（ADR-68）

    /// 「この人と同じ人をまとめて選ぶ」1 画面ぶんを取得する。
    /// `anchorClusterID` を渡すと、その人物を基準にする（人物一覧から特定の人を畳むとき）。
    public func batchReviewItem(anchorClusterID: Int? = nil,
                                excludingAnchors: Set<Int> = [],
                                excludingCandidates: Set<Int> = [],
                                limit: Int = 24) async -> FaceBatchReviewItem? {
        await store.batchReviewItem(minFaces: minFaces, anchorClusterID: anchorClusterID,
                                    excludingAnchors: excludingAnchors,
                                    excludingCandidates: excludingCandidates,
                                    limit: limit)
    }

    /// 一括レビューの回答。選ばれたクラスタをアンカーへ統合し、外されたものは「別人」として記録する。
    ///
    /// 統合後にアンカーの重心が育つため、同じアンカーで再取得すると**さらに遠い時期の
    /// クラスタが候補に入る**（＝人間の確認を種にした連鎖）。自動連鎖（ADR-56 で不採用）と違い、
    /// 各段でユーザーの確認を挟むので雪崩式の誤統合が起きない。
    /// 戻り値: 統合できなかった件数（別名どうし・同一写真で共起）。UI が結果を伝えるのに使う。
    @discardableResult
    public func answerBatch(anchorClusterID: Int, same: [Int], notSame: [Int]) async -> Int {
        var rejected = 0
        for id in same where id != anchorClusterID {
            // 一括レビューは小さなアバターを一覧から選ぶ＝1 対 1 の確認より確度が低く、件数も多い。
            // 学習には低い重みで入れる（ADR-68 追補6）。
            if await store.mergeClusters(from: id, into: anchorClusterID,
                                         confidence: .batch) != nil { rejected += 1 }
        }
        for id in notSame where id != anchorClusterID {
            await store.markNotSamePerson(clusterA: anchorClusterID, clusterB: id,
                                          confidence: .batch)
        }
        // 誤統合の痕跡（1 枚に同じ人物が 2 回）はその場で自動修復する。
        // ユーザーに毎回選ばせる操作ではない（実フィードバック・ADR-68 追補6）。
        await store.repairSamePhotoViolations()
        await loadPeople()
        return rejected
    }

    /// 「1 枚の写真に同じ人物が 2 回」を修復する（誤統合の痕跡・ADR-68 追補5）。
    /// 最良の 1 顔だけ残し、外した顔は負例として学習させる（再クラスタで再発しない）。
    @discardableResult
    public func repairSamePhotoViolations() async -> Int {
        let n = await store.repairSamePhotoViolations()
        if n > 0 { await loadPeople() }
        return n
    }

    /// 事後監査「この人物、実は 2 人では？」への回答（A3・ADR-69）。
    /// いいえ（別人）→ **クラスタを 2 つに分割**し、負例として学習する。
    /// はい（同じ人）→ 記録して二度と尋ねない（正例としてしきい値校正にも効く）。
    public func answerSplitCluster(clusterID: Int, groupBFaceIDs: [String], same: Bool) async {
        if same {
            await store.confirmSameGroup(clusterID: clusterID, groupBFaceIDs: groupBFaceIDs)
        } else {
            await store.splitCluster(clusterID: clusterID, faceIDs: groupBFaceIDs)
        }
        await loadPeople()
    }

    /// 「この写真は「◯◯」さんですか？」への回答（A2）。
    /// はい → 確認済み（アンカー＋正例）。いいえ → 分離（負例として学習）。
    public func answerIsThisPerson(faceID: String, yes: Bool) async {
        if yes {
            await store.confirmFace(faceID: faceID)
        } else {
            await store.reassignFace(faceID: faceID, toClusterID: nil)
        }
        await loadPeople()
    }

    // MARK: - 制約付き再クラスタリング（B2・ADR-46）

    /// クラスタ割り当て**規則**の版。しきい値以外のゲート規則を変えたら上げる（ADR-68）。
    /// 上げると次の夜間処理で全体が割り当て直される（顔の再スキャンは不要）。
    /// 1: ADR-57/58（マージンゲート＋サイズ適応）/ 2: ADR-68（競合を見る免除）/
    /// 3: ADR-68 追補（校正上限 0.70→0.55・実効しきい値の頭打ち）
    public static let clusterRuleVersion = 3

    /// 修正が増えていたら全体を割り当て直す（夜間スキャン完了後に呼ばれる）。
    /// 命名済み/確認済みクラスタは ID・名前を保持し、確認顔は must-link として固定。
    public func rebuildClustersIfNeeded() async {
        let markerKey = "faceRebuildCorrectionCount"
        let scanMarkerKey = "faceRebuildScannedCount"
        let dateMarkerKey = "faceRebuildLastDate"
        let defaults = UserDefaults.standard
        let current = await store.correctionCount()
        let scanned = await store.scannedCount()
        let lastRebuilt = defaults.integer(forKey: markerKey)
        let lastScanned = defaults.integer(forKey: scanMarkerKey)
        let lastDate = defaults.object(forKey: dateMarkerKey) as? Date
        // 発火条件（ADR-54 で拡張）: 修正が増えた／新規スキャンが 500 写真以上進んだ／
        // 30 日以上再クラスタしていない、のいずれか（順序依存の誤りを定期的に自己修復する）。
        let correctionsGrew = current > lastRebuilt
        let scansGrew = scanned - lastScanned >= 500
        let stale = lastDate.map { Date().timeIntervalSince($0) > 30 * 86_400 } ?? (scanned > 0)
        // 既定しきい値の変更（ADR-56 の 0.45→0.60 等）も再クラスタ対象（版上げ不要の調整を反映）。
        let thresholdKey = "faceRebuildBaseThreshold"
        let thresholdChanged = Float(defaults.double(forKey: thresholdKey)) != tuning.clusterThreshold
        // **割り当て規則**の変更も再クラスタ対象（ADR-68）。しきい値は同じでもゲートの規則が
        // 変われば結果は変わるので、規則に版を振って発火させる。版を上げれば既存ユーザーの
        // 分裂したクラスタが次の夜間処理で畳み直される（再スキャンは不要＝埋め込みは再利用）。
        let ruleKey = "faceRebuildRuleVersion"
        let ruleChanged = defaults.integer(forKey: ruleKey) != Self.clusterRuleVersion
        guard correctionsGrew || scansGrew || stale || thresholdChanged || ruleChanged else { return }
        let result = await store.rebuildClusters()
        defaults.set(current, forKey: markerKey)
        defaults.set(scanned, forKey: scanMarkerKey)
        defaults.set(Date(), forKey: dateMarkerKey)
        defaults.set(Double(tuning.clusterThreshold), forKey: thresholdKey)
        defaults.set(Self.clusterRuleVersion, forKey: ruleKey)
        Diagnostics.mark("faces: rebuild done — clusters=\(result.clusters) moved=\(result.moved) "
                         + "(corrections \(lastRebuilt)→\(current), scans \(lastScanned)→\(scanned), stale=\(stale))")
        // 再クラスタ後の品質を診断ログへ残す（分裂がどれだけ畳めたか・不変条件が破れていないかを
        // 実機で追えるようにする・ADR-68）。
        await logQualityReport()
        await loadPeople()
    }

    /// Developer Options 用: 即時再クラスタリング（動作検証）。
    public func debugRebuildClustersNow() async {
        let result = await store.rebuildClusters()
        Diagnostics.mark("faces: manual rebuild — clusters=\(result.clusters) moved=\(result.moved)")
        await loadPeople()
    }
}
