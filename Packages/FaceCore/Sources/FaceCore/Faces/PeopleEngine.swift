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
    /// 認識できた人物の**全件**（写真 `minFaces` 枚以上）。表示は `people`（フロア適用後）を使う。
    public private(set) var allPeople: [PersonInfo] = []

    /// **ピープルに表示する**人物。枚数フロア（`minPhotosForList`）を下回る無名の人物は出さない。
    ///
    /// ⚠️ 実フィードバック: 「2 枚とか 5 枚しか顔写真がない人はピープルに載せなくて良い」。
    /// たまたま写り込んだ人が大量に並ぶと、本当に見たい人が埋もれる（実機で 1,000 人超）。
    /// **名前を付けた人は枚数に関係なく必ず出す**——名前はユーザーが関心を表明した唯一の印なので、
    /// 枚数で消してはいけない（3 枚しかない親戚に名前を付けた、は普通に起きる）。
    public var people: [PersonInfo] {
        let floor = minPhotosForList
        return allPeople.filter { $0.name != nil || $0.count >= floor }
    }
    /// ピープルグループ（複数人物の名前付き束＝家族・チームなど）。人物一覧と同時に再解決する。
    public internal(set) var peopleGroups: [PeopleGroupInfo] = []
    public private(set) var isLoaded = false
    public private(set) var isScanning = false
    /// 未スキャン残り枚数（おおよそ）。
    public private(set) var remaining = 0

    @ObservationIgnored let store: FaceStore   // internal: 同モジュールの機能別 extension（PersonCleanup 等）が使う
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
    /// `setNeedsPeopleReload()` のデバウンス用。連続要求は最後の 1 回だけ生き残る（ADR-95）。
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    /// 「人物」として扱う最小の写真枚数（レビュー・検索・名前解決の母数）。
    /// 少ない断片も統合の対象にはしたいので、ここは低めに保つ。
    let minFaces = 3   // internal: レビュー（+Review）が同じ型の別ファイルにあるため
    /// **ホームのピープル列に出す**最小枚数（ADR-68 追補5）。
    /// 「5 枚以内の人は重要人物ではない」＝ **6 枚以上**をトップに出す（実フィードバック）。
    /// 数枚しか写っていない人はトップに並べる価値が薄く、成長期の断片も混ざって列が埋まる。
    /// 「すべて表示」では `minFaces`（3 枚以上）の全員を出すので、埋もれて見えなくなることはない。
    public static let minFacesForCarousel = 6

    // MARK: - ピープルに載せる最小枚数（実フィードバック）

    /// 既定のフロア。「2 枚・5 枚しか写っていない人」を排し、「よく写っている人」は残す線。
    /// ⚠️ ここは**表示だけ**の線で、学習（レビュー候補・名前解決・検索の接地）の母数は
    /// `minFaces`（3 枚）のまま。表示から消すために学習材料まで捨てない。
    public static let defaultMinPhotosForList = 10
    public static let minPhotosForListKey = "peopleMinPhotosForList"
    /// ユーザーが選べる段階（「すべて表示」のフィルタ）。
    public static let minPhotosChoices = [3, 5, 10, 20]

    /// ピープルに載せる最小枚数（永続・既定 `defaultMinPhotosForList`）。
    public var minPhotosForList: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Self.minPhotosForListKey)
            return stored > 0 ? stored : Self.defaultMinPhotosForList
        }
        set {
            guard newValue != minPhotosForList else { return }
            UserDefaults.standard.set(newValue, forKey: Self.minPhotosForListKey)
            // @Observable: `people` は `allPeople` から導出されるので、依存を触って再評価させる。
            allPeople = allPeople
        }
    }

    /// テスト用: 一覧を差し替える（表示フロアの検証用。ストアを立てずに済ませる）。
    func setPeopleForTesting(_ list: [PersonInfo]) { allPeople = list }

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

    /// 本番用ファクトリ。コンテナを開くディスク I/O をメインから外すため **オフメインで生成**する。
    /// ⚠️ 実行スレッドの分離はこれではなく `FaceStore.unownedExecutor`（専用キュー）の役目
    /// （既定 executor は**呼び出し元のスレッド**で走る＝`ModelStoreExecutor` に詳述）。
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
    ///
    /// ⚠️ メンバーキーは積まない（`includeMembers: false`）。人物アルバムだけが必要とするので
    /// `memberRefKeys(forPerson:)` で開いた画面が取りに来る（ADR-95）。
    public func loadPeople() async {
        // ⚠️ 内訳を測る（ADR-95 追記）。実機 diagnostics-41 でも、レビュー連続回答の 1 回ごとに
        //    メインが 540〜645ms 止まり、そのハングが `faces: people=` の直前で終わっていた。
        //    答えは「**off-main ではなかった**」——既定の ModelActor executor は呼び出し元の
        //    スレッドで走るため、ここの各段はメインで実行されていた（ADR-121 で専用キューへ）。
        let t0 = PerfTrace.nowNs()
        await store.apply(tuning: tuning)   // 冪等（変更が無ければ何もしない・ADR-70）
        PerfTrace.logSpan("people.load.tuning", ms: PerfTrace.msSince(t0))

        let t1 = PerfTrace.nowNs()
        let favorites = await favoriteRefKeysProvider?() ?? []
        PerfTrace.logSpan("people.load.favorites", ms: PerfTrace.msSince(t1))

        let t2 = PerfTrace.nowNs()
        let fresh = await store.peopleClusters(minFaces: minFaces, favoriteRefKeys: favorites,
                                               includeMembers: false)
        PerfTrace.logSpan("people.load.clusters", ms: PerfTrace.msSince(t2))
        isLoaded = true
        // ⚠️ 中身が同じなら**代入しない**。`@Observable` は代入だけで購読ビューを無効化するので、
        //    スキャン中や連続レビューでは「変化なしの再描画」が積み上がっていた（ADR-95）。
        guard fresh != allPeople else { return }
        allPeople = fresh
        Diagnostics.mark("faces: people=\(people.count)/\(allPeople.count) "
                         + "(>= \(minPhotosForList) photos or named; scanned floor \(minFaces), favs=\(favorites.count))")
        // グループは人物一覧に対する解決なので、一覧が変わったときだけ作り直せば足りる。
        await reloadPeopleGroups()
    }

    /// 連続する変更（顔スキャンのバッチ完了・レビューの連続回答）を**1 回の再読込にまとめる**。
    ///
    /// 実機（diagnostics-38）では 1 分間に 30 回 `loadPeople()` が走り、その 1 回ごとに
    /// フォアグラウンドが 600〜1000ms 固まっていた（1 分あたりのハング数＝発行回数と完全一致）。
    /// 一覧は「最終的に正しければよい」表示なので、静止するまで待って 1 回だけ出す（ADR-95）。
    public func setNeedsPeopleReload(quietMs: UInt64 = 700) {
        // レビュー UI 表示中は再発行を**保留**する（diagnostics-51）。人物が 900 級に育つと
        // 一覧の配り直し＝SwiftUI 再描画が 1 回 2〜4 秒のメインハングになり、回答のたびに
        // 引っかかっていた。レビュー中のカード進行は一覧に依存しないので、閉じるときに
        // 1 回だけ反映すれば十分。
        if reloadHoldCount > 0 {
            reloadPendingWhileHeld = true
            return
        }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: quietMs * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.loadPeople()
        }
    }

    /// レビュー UI（1対1レビュー・まとめて確認・整理）の表示中、人物一覧の再発行を保留する。
    /// ネスト可（複数画面が重なっても最後の 1 つが閉じるまで保留）。
    @ObservationIgnored private var reloadHoldCount = 0
    @ObservationIgnored private var reloadPendingWhileHeld = false

    /// ピープル関連の画面を開いているか（＝顔スキャンは譲る）。
    var isBrowsingPeople: Bool { reloadHoldCount > 0 }

    public func beginPeopleReloadHold() { reloadHoldCount += 1 }

    public func endPeopleReloadHold() {
        reloadHoldCount = max(0, reloadHoldCount - 1)
        guard reloadHoldCount == 0, reloadPendingWhileHeld else { return }
        reloadPendingWhileHeld = false
        Task { [weak self] in await self?.loadPeople() }
    }

    /// 笑顔の実測（refKey → 笑顔の顔数・スキャン済みのみ）。AI アルバムの `.smiling` 条件用（S10）。
    public func smilingFaceCounts() async -> [String: Int] {
        await store.smilingFaceCounts()
    }

    /// 1 人物のメンバー写真キー（束ねていれば全時期ぶん）。人物アルバムを開くときだけ呼ぶ。

    public func memberRefKeys(forPerson clusterID: Int) async -> [String] {
        await store.memberRefKeys(forPerson: clusterID)
    }

    /// このクラスタを含む「表示上の人物」。束ねられていれば**束ね先（主クラスタ）**の
    /// `PersonInfo` を返す（ADR-61 の 2 階層束ねでは、主クラスタが相手側に移ることがある）。
    /// 開いている人物アルバムを、束ねたあとの人物として描き直すために使う。
    public func person(containing clusterID: Int) async -> PersonInfo? {
        let linked = Set(await store.linkedClusterIDs(primary: clusterID))
        return allPeople.first { linked.contains($0.clusterID) }
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
        // ⚠️ **前面では起こさない**（実機 diagnostics-62/63）。方針は「操作している間は重い処理を
        // 一切動かさない」なので、前面で始めても内部の譲り判定で止まり、譲り待ちの上限で畳む。
        // ところが**畳むまでに入口の準備は済ませてしまう**——`scannedRefKeys()` は
        // ScannedPhoto を全件（実測 75,000 行超）読む。しかも `FaceStore` は単一の
        // `@ModelActor` なので、その間ピープル一覧・写真の人物名が後ろで待たされる。
        // 実測: ロック解除直後に 32,582 枚を対象に開始 → `face.pauseWait=30`（10 秒ごと）で
        // 譲り続け → **0 枚**で終了。準備のコストだけを払っていた。
        // 夜間（非アクティブ）と明示操作（デバッグ全開）は従来どおり通す。
        guard !BackgroundYield.isAppActive || BackgroundYield.debugForceHeavyWork else {
            Diagnostics.mark("faces: startScan skip — app is active (heavy work runs when idle)")
            isLoaded = true
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
            // クラウドの取得解像度・下限を変えた場合はクラウド分だけ測り直す（ADR-90）。
            await self.migrateCloudAnalysisIfNeeded()
            await self.tagger.scan(
                candidateRefKeys: candidateRefKeys,
                allowSimulator: allowSimulator,
                shouldPause: { [weak self] in
                    // 重い処理の共通方針（電源接続＋低電力OFF＋一定時間アイドル＋生成との
                    // 相互排他）は BackgroundYield.heavyShouldPause に一元化。端末内写真の顔検出は
                    // 通信不要なので Wi-Fi は要求しない（ローカルゲート）。
                    if BackgroundYield.heavyShouldPause() { return true }
                    // ⚠️ **ユーザーがピープルを触っている間は譲る**（ADR-142）。顔スキャンと
                    // 人物一覧・レビューの候補探索は**同じ `@ModelActor` を奪い合う**ので、
                    // スキャン中は一覧の読み込みが 0.4 秒 → 13 秒まで伸びていた（diagnostics-68）。
                    // レビュー表示中の保留（ADR-95）と同じ合図をここでも使う。
                    return self?.isBrowsingPeople ?? false
                },
                networkAllowed: {
                    // クラウド写真の顔検出はキャッシュ済みサムネDLを要するため回線ポリシーに従う。
                    NetworkStateMonitor.shared.networkAllowed()
                },
                onProgress: {
                    self.remaining = $0
                    BackgroundActivityMonitor.shared.faceScanRemaining = $0
                },
                // ⚠️ バッチごとに `loadPeople()` を直に呼ぶと、スキャン中ずっと 2 秒に 1 回
                //    人物リストを再発行し続けることになる（実機で 600〜1000ms のハングが
                //    その回数ぶん出ていた・ADR-95）。スキャン進捗の反映は急がないのでまとめる。
                onBatch: { [weak self] in self?.setNeedsPeopleReload() })
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

    /// 直前の判定の説明（nil＝戻せるものが無い）。レビュー画面の「戻す」に出す。
    ///
    /// ⚠️ 実フィードバック: 「ピープルの確認をしていると、たまに、間違った！と思うことがある」。
    /// 確認は連続で答える画面なので、**間違いに気づくのは次のカードが出た直後**。
    /// そこで戻せないと、あとから顔の管理を開いて手で直すことになる。
    ///
    /// ⚠️ 格納プロパティなので**型本体に置く**（extension には置けない）。更新は
    /// `PeopleEngine+Undo.swift` から行うため `internal(set)`——外部には従来どおり読み取り専用。
    public internal(set) var undoLabel: String?

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

    /// 顔の**全消去**が起きたときに呼ばれる（clusterID は 0 から振り直されるため）。
    ///
    /// ⚠️ `clusterID` は永続 ID ではない。全消去のあと再スキャンすると番号が再利用され、
    /// **別コンテナに残っている人物参照（クラウド共有の `sourceKey` 等）が別人を指す**。
    /// 共有では「次の反映で別人の写真を家族フォルダへ追加する」事故になる（レビュー指摘）。
    /// アプリ（Composition Root）がここで参照を無効化する。
    @ObservationIgnored public var onPersonIdentitiesInvalidated: (@MainActor () async -> Void)?

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
            // clusterID が振り直される＝外部が持つ人物参照は当てにならない。
            await onPersonIdentitiesInvalidated?()
            Diagnostics.mark("faces: scan pipeline v\(stored == 0 ? 1 : stored)→v\(current) "
                             + "— full rescan (carrying \(snapshot.count) names)")
            await loadPeople()
        }
        UserDefaults.standard.set(current, forKey: Self.faceScanVersionKey)
    }

    /// クラウド顔解析の版（ADR-90）。取得解像度・顔ピクセル下限を変えたら上げる。
    /// **ローカルには影響させない**（元から 1024px で処理済み＝測り直す理由がない）。
    static let cloudAnalysisVersion = 1
    private static let cloudAnalysisVersionKey = "faceCloudAnalysisVersion"

    /// 版が上がっていたらクラウド分のスキャン結果だけ捨てて測り直す。
    /// クラスタと命名は残るので、再スキャンした顔は既存の人物へ合流する。
    private func migrateCloudAnalysisIfNeeded() async {
        let stored = UserDefaults.standard.integer(forKey: Self.cloudAnalysisVersionKey)
        guard stored < Self.cloudAnalysisVersion else { return }
        let discarded = await store.resetCloudScans()
        if discarded > 0 {
            Diagnostics.mark("faces: cloud analysis v\(stored)→v\(Self.cloudAnalysisVersion) "
                             + "— discarded \(discarded) cloud scans (local kept)")
            await loadPeople()
        }
        UserDefaults.standard.set(Self.cloudAnalysisVersion, forKey: Self.cloudAnalysisVersionKey)
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
        allPeople.compactMap { $0.name }.filter { !$0.isEmpty }
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
        for key in Self.refKeyCandidates(for: id) {
            let boxes = await store.faceBoxes(refKey: key, clusterID: clusterID)
            if !boxes.isEmpty { return boxes }
        }
        return []
    }


    /// 回答の生データ（CSV）と要約。要約は診断ログにも残す（ADR-148）。
    public func exportAnswerBasis() async -> (csv: String, summary: String) {
        let csv = await store.answerSamplesCSV()
        let summary = await store.answerBasisSummary()
        Diagnostics.mark(summary)
        return (csv, summary)
    }

    /// いま効いている基準（比較のために画面へ出す）。
    public func currentThresholds() async -> (calibrated: Float, base: Float, askBar: Float) {
        await store.currentThresholds()
    }

    /// 1〜2 枚の断片を、確立した人物へまとめる（ADR-154）。手動実行用。
    @discardableResult
    public func absorbFragments() async -> FragmentAbsorbResult {
        Diagnostics.breadcrumb("people.absorbFragments")
        // 結果（0 件も含む）の記録は `FaceStore.absorbFragments` が必ず行う（ADR-157）。
        let result = await store.absorbFragments()
        if result.absorbed > 0 {
            await clearUndoHistory()   // 大量に動くので、戻す先が変わっている
            await loadPeople()
        }
        return result
    }

    /// あなたの回答から見た「同じ人／別人」の分かれ方（ADR-148）。読み取り専用。
    public func answerSimilarityProfile(kind: AnswerSimilarityProfile.Kind) async
        -> AnswerSimilarityProfile {
        await store.answerSimilarityProfile(kind: kind)
    }

    /// 判定の内訳（Developer Options のチューニング用・ADR-135）。読み取り専用。
    public func decisionReport(clusterID: Int, limit: Int = 12,
                               outlierLimit: Int = 24) async -> PersonDecisionReport? {
        Diagnostics.breadcrumb("inspector.report cluster=\(clusterID) n=\(limit) o=\(outlierLimit)")
        let report = await store.decisionReport(clusterID: clusterID, limit: limit,
                                                outlierLimit: outlierLimit)
        Diagnostics.breadcrumb("inspector.report: rendered "
                               + "neighbors=\(report?.neighbors.count ?? -1) "
                               + "outliers=\(report?.outliers.count ?? -1)")
        return report
    }

    /// 2 人が同じ写真に一緒に写っている箇所（統合できない理由の提示用・ADR-146）。
    public func samePhotoConflicts(between a: Int, and b: Int) async
        -> [(refKey: String, first: PersonInfo.Face, second: PersonInfo.Face)] {
        await store.samePhotoConflicts(between: a, and: b)
    }

    /// この写真に**1 人だけ**写っているときのその人物（写真ビューの「この人は XX ではない」用）。
    /// 複数人・0 人なら nil（どの人を直すのかが決まらないため出さない）。
    public func solePerson(inItem itemID: String) async -> PersonInfo? {
        for key in Self.refKeyCandidates(for: itemID) {
            guard let clusterID = await store.solePersonClusterID(refKey: key) else { continue }
            return await person(containing: clusterID)
        }
        return nil
    }

    /// 取り消しの説明に使う人物名（一覧に無ければ内部 ID で表す）。
    func label(_ clusterID: Int) -> String {
        allPeople.first { $0.clusterID == clusterID }?.displayName ?? "Person \(clusterID)"
    }

    /// 表示側の写真 ID から台帳の refKey 候補を作る（ローカル/クラウド/そのまま）。
    static func refKeyCandidates(for id: String) -> [String] {
        var candidates: [String] = []
        if PhotoRef.decode(id) != nil { candidates.append(id) }
        candidates.append(PhotoRef.local(id).encoded)
        candidates.append(PhotoRef.cloud(id).encoded)
        return candidates
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
        await clearUndoHistory()   // 消したあとの世界には戻す先が無い
        if includingCorrections {
            await store.resetIncludingCorrections()
        } else {
            await store.reset()
        }
        // clusterID は 0 から振り直される。人物を指す外部参照を無効化させる。
        await onPersonIdentitiesInvalidated?()
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
}
