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

    /// この人物が**まだ在るか**（共有セットの作成元が現存するか等の判定用）。
    ///
    /// ⚠️ **存在の判定に `people` を使わない。** `people` は「ピープルに載せるか」という
    /// **表示の線**（ADR-125・無名でフロア未満を隠す）であって、人物が在るかどうかではない。
    /// 表示の線で存在を判定すると、写真が減って（削除・「XX ではない」・再クラスタ）フロアを
    /// 下回った瞬間に、その人物は**消えた**と読まれる。実害の例: 無名のまま共有したセットが、
    /// 枚数が 10 を割った時点で「作成元が無い孤児」と判定され、以後メンバーに追従しなくなる。
    /// 同じ理由で `person(containing:)` も `displayName(for:)` も `allPeople` を見ている。
    public func personExists(clusterID: Int) -> Bool {
        allPeople.contains { $0.clusterID == clusterID }
    }

    /// ピープルグループ（複数人物の名前付き束＝家族・チームなど）。人物一覧と同時に再解決する。
    public internal(set) var peopleGroups: [PeopleGroupInfo] = []
    public private(set) var isLoaded = false
    /// 顔スキャンが走っているか。**状態は `scan` が持つ**（ADR-198）——`SingleFlightTask` は
    /// `@Observable` なので、この計算プロパティ越しでも SwiftUI が追従する。
    public var isScanning: Bool { scan.isRunning }
    /// 未スキャン残り枚数（おおよそ）。
    /// **スキャン中の進捗**（この実行の残り）。止まると 0 に戻る。
    /// ⚠️ 名前が `remaining` だったころ、3 か所で「残作業」と読み違えられた
    /// （完了判定・夜間の枠配分・停滞検出）。いずれも「終わった」と「始められなかった」を
    /// 同じ 0 で扱ってしまう。**残作業は `faceBacklog`**（ADR-207）。
    public private(set) var scanProgressRemaining = 0

    /// **スキャンしていなくても答えられる顔の残作業**（ADR-207）。
    ///
    /// ⚠️ `remaining` はスキャン中しか意味を持たない（止まると 0 に戻る）。
    /// 「終わったから 0」と「始められなかったから 0」が同じ値になるので、
    /// 完了の判定にそのまま使うと**残作業を抱えたまま「すべて解析済み」と表示する**。
    /// こちらは最後に測った値を保ち、回線待ちで外したぶん（クラウド）も足して持つ。
    /// - nil: この起動でまだ一度も測っていない（＝分からない。0 と区別すること）
    public private(set) var faceBacklog: Int?
    /// **今ここで進められる残り**（回線待ちのクラウド分を含まない）。nil＝この実行では測っていない。
    /// ⚠️ 「分からない」を 0（＝終わった）に丸めない（ADR-207）。モデルの解放はこれを見る。
    @ObservationIgnored private var faceRemainingHere: Int?

    /// 表示・編集に使う**現行世代**の台帳。影の世代の切り替え（`promoteShadowIfReady`）で差し替わる（ADR-186）。
    @ObservationIgnored var store: FaceStore   // internal: 同モジュールの機能別 extension（PersonCleanup 等）が使う
    @ObservationIgnored var tagger: FaceTagger
    @ObservationIgnored let faceProvider: FacePerceptionProvider?
    /// **影の世代**（ADR-186）: 同梱モデルの ID が現行世代と違うとき、新モデルで別コンテナを育てる。
    /// スキャンはこちらへ、表示は `store`（旧世代）のまま。網羅が閾値に達したら `promoteShadowIfReady` で切り替える。
    @ObservationIgnored var shadowStore: FaceStore?
    /// 影の世代を切り替える網羅の閾値（候補に対するスキャン済みの割合）。
    static let shadowPromotionCoverage = 0.9
    static let activeFaceModelKey = "faces.activeModel"
    /// お気に入り写真の refKey 集合（"L-…"）を返す seam（アプリ側＝PhotoKit が実装）。
    /// 代表写真の自動選択で「お気に入りの写真を優先」するために使う。nil なら優先なし。
    @ObservationIgnored private let favoriteRefKeysProvider: (() async -> Set<String>)?
    /// クラウド path 群 → **EXIF の撮影日時**（ADR-218・アップロード時刻は返さない）。
    /// 先にスキャンした顔の撮影日を、分かった分から埋め直すのに使う。
    @ObservationIgnored let cloudCaptureDates: (@Sendable ([String]) async -> [String: Date])?
    /// 顔スキャン。二重起動の抑止・世代ガード・明け渡しは `SingleFlightTask` が持つ（ADR-198。
    /// 以前は `scanTask` / `scanGeneration` / `isScanning` の 3 つを手で管理していた）。
    @ObservationIgnored let scan = SingleFlightTask()
    /// 直近のスキャン候補（reset 後の再スキャンに使う）。
    @ObservationIgnored private var lastCandidates: [String] = []
    @ObservationIgnored private var lastAllowSimulator = false
    /// 人物一覧の再読込を間引く（連続する変更を 1 回にまとめる・ADR-95/198）。
    @ObservationIgnored private let reload = DebouncedTask(quietMilliseconds: 700)
    /// 直近の `loadPeople()` の所要（秒）。次の静止時間を決めるのに使う。
    @ObservationIgnored private var lastPeopleLoadSeconds: TimeInterval = 0

    /// 再読込の静止時間（純ロジック・テスト対象）。
    ///
    /// ⚠️ **重い一覧ほど長く空ける**（実機ログ diagnostics-93）。固定 700ms だったので、
    /// 1 回 2.6 秒（最大 8.7 秒）かかる一覧が「終わった直後にまた予約」で走り続け、
    /// **18 分で 160 回・合計 414 秒**——顔の `@ModelActor` の 4 割がここで埋まっていた
    /// （同じ actor を使う写真の人物名・レビュー候補・スキャンが後ろで待つ）。
    /// 一覧は「最終的に正しければよい」表示なので、重いときは素直に間隔を空ける。
    /// ⚠️ 頭打ちは **8 秒**（レビュー指摘）。`DebouncedTask` は「前の実行の終わり」から静止時間を
    /// 測るので、実効の間隔は「所要 ＋ 静止時間」。所要が数秒まで伸びる端末で上限を 15 秒にすると、
    /// スキャン中のバッチ通知（8 バッチ＝128 枚ごと）より間隔が長くなり、
    /// **スキャンが終わるまで人物一覧が一度も更新されない**ことがある。
    static func reloadQuietMilliseconds(lastLoadSeconds: TimeInterval) -> UInt64 {
        let base: TimeInterval = 0.7
        let costBased = min(lastLoadSeconds * 4, 8.0)
        return UInt64(max(base, costBased) * 1000)
    }

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
         cloudCaptureDates: (@Sendable ([String]) async -> [String: Date])? = nil,
         store: FaceStore? = nil,
         shadowStore: FaceStore? = nil) {
        let store = store ?? FaceStore()
        self.store = store
        self.faceProvider = faceProvider
        self.favoriteRefKeysProvider = favoriteRefKeysProvider
        self.cloudCaptureDates = cloudCaptureDates
        self.shadowStore = shadowStore
        // スキャンは影の世代があればそちらへ（新モデルの埋め込みを旧世代のクラスタに混ぜない）。
        self.tagger = FaceTagger(store: shadowStore ?? store, provider: faceProvider)
        // アクティビティバーへの鏡写し。⚠️ スキャン本体の末尾でやると、止めた直後に始まった
        // 新スキャンの表示を旧タスクが落とす（ADR-198）。世代を知っている側から通知してもらう。
        scan.onStateChange = { [weak self] running in
            BackgroundActivityMonitor.shared.isScanningFaces = running
            if !running {
                BackgroundActivityMonitor.shared.faceScanRemaining = 0
                self?.scanProgressRemaining = 0
                // ⚠️ `faceBacklog` は**ここで 0 にしない**。止まった理由（終わった／譲った）を
                // 区別できなくなる。本当の残りはスキャン側が `onBacklog` で置いていく。
            }
        }
    }

    /// 現行世代（表示に使っている台帳）の顔モデル ID。未記録なら既存データの世代。
    static func activeFaceModelID(_ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: activeFaceModelKey) ?? ModelGeneration.legacyFace
    }

    /// 本番用ファクトリ。コンテナを開くディスク I/O をメインから外すため **オフメインで生成**する。
    /// ⚠️ 実行スレッドの分離はこれではなく `FaceStore.unownedExecutor`（専用キュー）の役目
    /// （既定 executor は**呼び出し元のスレッド**で走る＝`ModelStoreExecutor` に詳述）。
    ///
    /// ADR-186: 同梱モデルの ID（`faceProvider.modelID`）が現行世代と違えば、**影の世代**のコンテナも開く。
    /// 表示は現行世代のまま、スキャンは影へ。網羅が閾値に達したら切り替える（DB を消さない）。
    public static func makeWithOffMainStore(
        faceProvider: FacePerceptionProvider?,
        favoriteRefKeysProvider: (() async -> Set<String>)? = nil,
        cloudCaptureDates: (@Sendable ([String]) async -> [String: Date])? = nil
    ) async -> PeopleEngine {
        let active = activeFaceModelID()
        let bundled = faceProvider?.modelID ?? active
        // 起動背景の SwiftData 初期化（ユーザーが直接待つ処理ではない）＝ .utility へ（提案2）。
        let store = await Task.detached(priority: .utility) { FaceStore(modelID: active) }.value
        var shadow: FaceStore?
        if bundled != active, faceProvider?.isAvailable == true {
            shadow = await Task.detached(priority: .utility) { FaceStore(modelID: bundled) }.value
            Diagnostics.mark("faces: model \(active) → \(bundled) — growing shadow generation (\(FaceStore.containerName(for: bundled)))")
        }
        // ADR-187: 消えたクラスタを指したままの顔（旧実装の掃除・付け替えの名残）は起動時に未割当へ戻す。
        // 放置すると、その ID が別人に再利用されたときに黙って別人のアルバムへ合流する。
        let orphans = await store.repairOrphanFaces()
        if orphans > 0 { Diagnostics.mark("faces: repaired \(orphans) orphan face(s) at launch (ADR-187)") }
        return PeopleEngine(faceProvider: faceProvider,
                            favoriteRefKeysProvider: favoriteRefKeysProvider,
                            cloudCaptureDates: cloudCaptureDates,
                            store: store, shadowStore: shadow)
    }

    /// 顔モデルが同梱され利用可能か（未同梱ならピープルは無効＝空表示）。
    public var isFaceModelAvailable: Bool { faceProvider?.isAvailable ?? false }

    /// 永続済みのクラスタからピープル一覧を読み込む。
    /// 代表写真はユーザー選択（保存済み）→ お気に入り写真 → 認識した写真の先頭、の順で決まる。
    ///
    /// ⚠️ メンバーキーは積まない（`includeMembers: false`）。人物アルバムだけが必要とするので
    /// `memberRefKeys(forPerson:)` で開いた画面が取りに来る（ADR-95）。
    public func loadPeople() async {
        // ⚠️ **最後まで**測る（レビュー指摘）。次の間引きの間隔はこの所要から決まる（ADR-225）ので、
        // 一覧の代入（SwiftUI の再発行＝diagnostics-51 で 2〜4 秒）とグループの作り直しを
        // 含めないと、重い回ほど間引きが効かない。
        // ⚠️ **中断を跨いだ回は捨てる**（ADR-80）。`PerfTrace` の時計はアプリのサスペンド中も進むので、
        // 背面に落ちた回を採ると数十〜数百秒になり、以後ずっと上限（15 秒）に張り付く。
        let epoch = ProcessSuspension.epoch
        let measureStart = PerfTrace.nowNs()
        defer {
            if !ProcessSuspension.didSuspend(since: epoch) {
                lastPeopleLoadSeconds = Double(PerfTrace.msSince(measureStart)) / 1000
            }
        }
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
    public func setNeedsPeopleReload() {
        // レビュー UI 表示中は再発行を**保留**する（diagnostics-51）。人物が 900 級に育つと
        // 一覧の配り直し＝SwiftUI 再描画が 1 回 2〜4 秒のメインハングになり、回答のたびに
        // 引っかかっていた。レビュー中のカード進行は一覧に依存しないので、閉じるときに
        // 1 回だけ反映すれば十分。
        if reloadHoldCount > 0 {
            reloadPendingWhileHeld = true
            return
        }
        reload.schedule(quietMilliseconds: Self.reloadQuietMilliseconds(lastLoadSeconds: lastPeopleLoadSeconds)) {
            [weak self] in await self?.loadPeople()
        }
    }

    /// レビュー UI（1対1レビュー・まとめて確認・整理）の表示中、人物一覧の再発行を保留する。
    /// ネスト可（複数画面が重なっても最後の 1 つが閉じるまで保留）。
    @ObservationIgnored private var reloadHoldCount = 0
    @ObservationIgnored private var reloadPendingWhileHeld = false
    @ObservationIgnored private var editPendingWhileHeld = false

    /// ピープル関連の画面を開いているか（＝顔スキャンは譲る）。
    var isBrowsingPeople: Bool { reloadHoldCount > 0 }

    public func beginPeopleReloadHold() { reloadHoldCount += 1 }

    public func endPeopleReloadHold() {
        reloadHoldCount = max(0, reloadHoldCount - 1)
        guard reloadHoldCount == 0 else { return }
        // 保留中に人物の構成が変わっていれば、閉じるときに 1 回だけ知らせる。
        if editPendingWhileHeld {
            editPendingWhileHeld = false
            editVersion &+= 1
            scheduleEditFollowUp()
        }
        guard reloadPendingWhileHeld else { return }
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
    /// ※ 一時停止で滞留した既存スキャンは、ゲートが開けば（`BackgroundYield.shouldYield()` が
    ///   false になれば）**自分で再開**するので、force のような再生成は行わない（旧実装の await 詰まり
    ///   を撤去）。生成フラグ滞留の安全弁は `BackgroundActivityMonitor.isGeneratingAlbums`（時間失効）と
    ///   デバッグ全開時の相互排他バイパスが担う。
    /// 進行中の顔スキャンを**明示的に止める**（ADR-79）。フォアグラウンド復帰で呼ぶ。
    /// `FaceTagger` のトリクルは 1 枚ごとに `Task.isCancelled` を見るため、実行中の 1 枚が
    /// 終わり次第すぐ抜ける。スキャンは差分（未処理 refKey）ベースなので次窓で続きから再開する。
    /// `reset(includingCorrections:)` と違い**完了を待たない**（復帰時にメインを塞がないため）。
    public func stopScan() {
        guard scan.isRunning else { return }
        // 世代ガードと進捗フラグの片付けは `SingleFlightTask` が持つ（ADR-198）。
        scan.stop()
        Diagnostics.mark("faces: stopScan (foreground return)")
    }

    /// **スキャンせずに顔の残作業を測る**（ADR-207）。
    ///
    /// ⚠️ スキャンが始められなかった回（ゲートが閉じた・シミュレータ・取り消し）でも
    /// 残作業は分かっていないと、「終わったから 0」と区別がつかない。
    /// 走査済みの refKey を 1 回引くので安くはない——**まだ一度も測っていないときだけ**
    /// 呼ぶこと（以後はスキャン側が `onBacklog` で更新する）。
    /// - Returns: 測ったか（モデル未同梱・既知のときは測らない）。
    @discardableResult
    public func measureBacklogIfUnknown(candidateRefKeys: [String]) async -> Bool {
        guard isFaceModelAvailable, faceBacklog == nil else { return false }
        // ⚠️ **スキャンが走る側の台帳で測る**。影の世代（モデル更新中）はスキャンが
        // そちらへ向かうので、現行世代で測ると「もう全部済んでいる」と出てしまう。
        let pending = await (shadowStore ?? store).pendingCount(candidateRefKeys: candidateRefKeys)
        faceBacklog = pending
        Diagnostics.mark("faces: backlog measured without scanning — \(pending)")
        return true
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
        // 一時停止で滞留したスキャンは、ゲートが開けば（shouldYield()=false）内部の waitWhilePaused で
        // 自分で再開する（旧: force による差し替えは isRunning レースで詰まったため撤去）。真因の画像ロード
        // ハング（PHAssetImageLoader）は別途修正済みなので、再開後は正常に検出まで進む。
        guard !scan.isRunning else {
            Diagnostics.mark("faces: startScan skip — already running (resumes when gate opens)")
            return
        }
        // ⚠️ **いま動けないなら起こさない**（実機 diagnostics-62/63）。始めても内部の譲り判定で止まり、
        // 譲り待ちの上限で畳むが、**畳むまでに入口の準備は済ませてしまう**——`scannedRefKeys()` は
        // ScannedPhoto を全件（実測 75,000 行超）読む。しかも `FaceStore` は単一の
        // `@ModelActor` なので、その間ピープル一覧・写真の人物名が後ろで待たされる。
        // 実測: ロック解除直後に 32,582 枚を対象に開始 → `face.pauseWait=30`（10 秒ごと）で
        // 譲り続け → **0 枚**で終了。準備のコストだけを払っていた。
        // ⚠️ 入口は**譲りとまったく同じ式**で判定する（ADR-196）。以前は入口が
        // `heavyWorkAllowedLocal`、譲りが `heavyShouldPause()` で、前者は一括ロード・生成中を
        // 見ていなかった。結果「入ってよい」と言われて `scannedRefKeys()`（75,000 行）を読んでから
        // 譲り待ちに入り、60 秒で 0 枚のまま畳む（diagnostics-62/63 の「入口代だけ払う」）。
        // ブースト・デバッグ全開の免除は `BackgroundYield.exemption` の中に入っている。
        guard BackgroundYield.allows(.localTrickle) else {
            Diagnostics.mark("faces: startScan skip — heavy work not allowed right now (policy)")
            isLoaded = true
            return
        }
        Diagnostics.mark("faces: startScan → begin (candidates=\(candidateRefKeys.count) allowSim=\(allowSimulator))")
        // ⚠️ `.background` を明示する（レビュー指摘）。素の `Task { }` は呼び出し元の
        // 優先度を引き継ぐので、駆動役（`.userInitiated`）から起こされると顔検出が
        // UI 操作と CPU を奪い合う。
        scan.start(priority: .background) { [weak self] in
            guard let self else { return }
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
                    // 相互排他）は BackgroundYield.shouldYield() に一元化。端末内写真の顔検出は
                    // 通信不要なので Wi-Fi は要求しない（ローカルゲート）。
                    if BackgroundYield.shouldYield() { return true }
                    // ⚠️ **ユーザーがピープルを触っている間は譲る**（ADR-142）。顔スキャンと
                    // 人物一覧・レビューの候補探索は**同じ `@ModelActor` を奪い合う**ので、
                    // スキャン中は一覧の読み込みが 0.4 秒 → 13 秒まで伸びていた（diagnostics-68）。
                    // レビュー表示中の保留（ADR-95）と同じ合図をここでも使う。
                    return self?.isBrowsingPeople ?? false
                },
                networkAllowed: {
                    // クラウド写真の顔検出はキャッシュ済みサムネDLを要するため回線ポリシーに従う。
                    // ⚠️ モニタを直読みしない（ADR-196）。ブーストは回線ポリシーを免除するので、
                    // 直読みだと「全力で解析します」と言いながらクラウド分を落とし、
                    // さらに「すべて解析済みです」と嘘の完了を出す（レビュー指摘）。
                    !BackgroundYield.verdict(for: .cloudTrickle).blocks(.networkBlocked)
                },
                onProgress: {
                    self.scanProgressRemaining = $0
                    BackgroundActivityMonitor.shared.faceScanRemaining = $0
                },
                onBacklog: { todo, deferred in
                    // ⚠️ `onProgress` とは**別の事実**。あちらは「この実行の残り」で、
                    // 進捗バーと `drainUntilIdle` が読む。こちらは「本当の残作業」で、
                    // 回線待ちで今回は外したクラウド分も含む。混ぜると、Wi-Fi が無い夜に
                    // 窓が畳めなくなる（`drainUntilIdle` が 0 にならない）。
                    self.faceBacklog = todo + deferred
                    // ⚠️ **「今ここで進められる残り」は別**（レビュー指摘）。モデルを手放してよいかは
                    // こちらで決める——回線待ちのクラウド分（`deferred`）は今夜どうやっても
                    // 減らないので、それを理由に顔モデルを抱え続けると ADR-223 が一度も効かない。
                    self.faceRemainingHere = todo
                },
                // ⚠️ バッチごとに `loadPeople()` を直に呼ぶと、スキャン中ずっと 2 秒に 1 回
                //    人物リストを再発行し続けることになる（実機で 600〜1000ms のハングが
                //    その回数ぶん出ていた・ADR-95）。スキャン進捗の反映は急がないのでまとめる。
                onBatch: { [weak self] in self?.setNeedsPeopleReload() })
            // ⚠️ **ここで取り消しを見て降りてはいけない**（レビュー 11 周目で入れ、13 周目で撤回）。
            // 残作業が窓 1 回で終わらない限り、productive な夜は**必ず**期限切れ＝取り消しで
            // 終わる。取り消しで降りると、下の 3 つは「何も進まなかった夜」にしか走らなくなる
            // ——名前の段階的な復元（版上げ後の数晩がかり）も、修正を全体へ広げる夜間の
            // 自己修復（ADR-46 B2）も、**進んだ夜には一度も走らない**という逆転が起きる。
            // 元の懸念（窓を畳んだ後に全再クラスタが始まる）は実在するが、直し方が要る
            // ——`unresolved-problems.md` に記録した。
            // B2: スキャン完了後、修正が増えていれば制約付き再クラスタリングで全体を最適化
            //（夜間ウィンドウ内・数秒・順序依存の誤りを解消する）。
            // 版上げ再スキャン中なら、進んだ分だけ名前を段階的に戻す（数晩に分かれても可）。
            await self.reapplyCarryoverNames()
            if !BackgroundYield.shouldYield() {
                await self.rebuildClustersIfNeeded()
            }
            // ADR-186: 影の世代が十分育っていれば、ここで現行世代に切り替える。
            await self.promoteShadowIfReady(candidateCount: candidateRefKeys.count)
            // ⚠️ **顔モデルを次の工程まで持ち越さない**（ADR-223・実機ログ diagnostics-88）。
            // このあと窓ではタグ付け → CLIP 埋め込みが続く。顔モデル（約 300MB）を抱えたまま
            // CLIP の塔を読むと、窓のピークが 650MB になる。手放すかの判断（前面か・残作業が
            // あるか）は実装側（`MobileCLIPKit`）に任せる。
            // ⚠️ **測れていないなら知らせない**（レビュー指摘）。`FaceTagger.scan` は
            // 早期 return（既に実行中・シミュレータ・provider 無し）では `onBacklog` を
            // 一度も呼ばないので、ここで古い値を使うと「終わった」と誤解して
            // **まだ走っている旧スキャンからモデルを取り上げる**。
            if let remaining = self.faceRemainingHere {
                self.faceRemainingHere = nil
                self.onScanFinished?(remaining)
            }
            // 実行中フラグ・進捗の片付けは `scan.onStateChange`（世代を知っている側）が行う。
        }
    }

    /// スキャンが 1 巡終わったときに呼ぶ（引数＝残作業）。実体はアプリが差す
    /// ——顔モデルを手放すかどうかを決めるため（ADR-223・`MobileCLIPKit` は FaceCore を知らない）。
    @ObservationIgnored public var onScanFinished: (@MainActor (Int) -> Void)?

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
    static let faceScanVersionKey = "faceScanVersion"

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

    /// ユーザーが人物を**手で直した**直後に呼ばれる（「XX ではない」「別の人」・付け替え・統合・分割）。
    /// 人物条件を持つ AI アルバムは評価時のスナップショットなので、アプリ（Composition Root）が
    /// ここで条件を満たさなくなった写真を外す（実フィードバック: AI アルバムで直しても変化なし）。
    /// スキャンの進行では呼ばない（そちらは通常の再評価に任せる）。
    @ObservationIgnored public var onPeopleEdited: (@MainActor () async -> Void)?
    /// 手動修正のたびに増える版。メンバー限定の写真画面（束ねグループのアルバム等）は
    /// これを `onChange` で見て、開いたまま描き直す（写真ごとの汎用メニューから直したとき）。
    public private(set) var editVersion = 0
    /// 編集後の後追い（AI アルバム掃除）。走行中に次の操作が来たら 1 回だけ拾い直す（ADR-198）。
    @ObservationIgnored private let editFollowUp = SingleFlightTask()

    /// 手動修正のあとの一覧更新＋通知（`PeopleEngine+Edit` の各操作から呼ぶ）。
    ///
    /// ⚠️ 通知（AI アルバムの掃除）は**待たない**。実フィードバック「人物アルバムで
    /// 『XX ではない』を選んでも再描画されない。ホームに戻って入り直すと消えている」——
    /// 呼び出し側（人物アルバムの `reload`）はこの戻りを待ってから描き直すが、AI アルバムの
    /// 掃除は人物条件のあるアルバムごとに全顔の名前表を引いていて数十秒かかり、その間
    /// 画面が古いままだった。ユーザーが待っている描き直しを、誰も待っていない掃除の後ろに
    /// 並べない（ADR-122 と同じ向き）。掃除は連続操作を 1 回にまとめて背景で回す。
    func loadPeopleAfterEdit() async {
        await loadPeople()
        notifyPeopleEdited()
    }

    /// 「人物の構成が利用者の操作で変わった」ことだけを知らせる（一覧の再読み込みは含まない）。
    ///
    /// ⚠️ **レビュー画面の回答からも呼ぶ**（レビュー指摘）。統合・分割・「この人ではない」は
    /// どれも人物の構成を変える操作なのに、レビュー経由だと `editVersion` が上がらず
    /// `onPeopleEdited` も走っていなかった。結果、**分けたばかりの人物の写真が
    /// AI アルバムに残り**、開いたままのグループアルバムも描き直されない
    /// （`onPeopleEdited` の説明は「XX ではない・付け替え・統合・分割」を挙げているのに、
    /// その 4 つのどれもレビュー経由では通っていなかった）。
    ///
    /// 一覧の再読み込みと**分けてある**のは、レビュー表示中は再発行を保留したいから
    /// （`setNeedsPeopleReload` の保留は 900 人規模で 2〜4 秒のメインハングを避けるため）。
    func notifyPeopleEdited() {
        // ⚠️ **レビュー表示中はためる**（レビュー 13 周目）。後追い（AI アルバムの掃除）は
        // 顔の台帳を**全件**引くので、回答 1 回ごとに出すと、回答そのものが待つ
        // `@ModelActor` の列に毎回その全件走査が割り込む（diagnostics-68 の再来）。
        // ADR-95・diagnostics-51 で回答の経路から重い処理を外したのと同じ理由。
        // 閉じるときに 1 回だけ出せば、掃除の目的（分けた人物の写真を落とす）は果たせる。
        if reloadHoldCount > 0 {
            editPendingWhileHeld = true
            return
        }
        editVersion &+= 1
        scheduleEditFollowUp()
    }

    /// 背景の後追い（AI アルバム掃除）。走行中に次の操作が来たら、終わってからもう 1 回だけ回す。
    private func scheduleEditFollowUp() {
        guard onPeopleEdited != nil else { return }
        editFollowUp.coalesce { [weak self] in await self?.onPeopleEdited?() }
    }

    /// テスト・設定画面用: 進行中の後追いが終わるまで待つ。
    public func awaitEditFollowUp() async { await editFollowUp.waitUntilIdle() }

    /// 版が上がっていたら、命名スナップショットを取ってから全消去→再スキャンに移行する。
    /// 修正ジャーナル（FaceCorrection）は残す（負例・校正はモデル不変のため引き続き有効）。
    private func migrateScanVersionIfNeeded() async {
        // ADR-186: 影の世代を育てている間は版上げの全再スキャンをしない（旧世代は凍結・
        // 新世代は最初から新パイプライン）。切り替え時に版を記録する。
        guard shadowStore == nil else { return }
        let stored = UserDefaults.standard.integer(forKey: Self.faceScanVersionKey)
        let current = effectiveScanVersion
        guard stored < current else { return }
        if await store.scannedCount() > 0 {
            let snapshot = await store.namedClusterEntries()
            if !snapshot.isEmpty { saveCarryover(NameCarryover(savedAt: Date(), entries:
                snapshot.map { .init(name: $0.name, memberRefKeys: $0.memberRefKeys) })) }
            await store.reset()
            // ⚠️ **控えも捨てる**（レビュー指摘）。`reset()` は `undoStack` を消さないので、
            // 「戻す」の行が残ったまま押せてしまう。押すと消えたはずのクラスタ ID の行を
            // **名前つき・顔ゼロで作り直し**、空の人物が一覧に居座る。
            // 再クラスタ・`reset(includingCorrections:)` は同じ理由で既にそうしている。
            await clearUndoHistory()
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
    /// ⚠️ ここも**控えを捨てる**（レビュー 13 周目）。`resetCloudScans` は中で
    /// `rebuildClusters()` を呼ぶので、クラスタ ID と構成が変わる＝戻す先が無くなる。
    /// 版上げの全再スキャン・モデル世代の切り替え・再クラスタは既にそうしており、
    /// **ここだけ 10 行違いで漏れていた**。
    private func migrateCloudAnalysisIfNeeded() async {
        let stored = UserDefaults.standard.integer(forKey: Self.cloudAnalysisVersionKey)
        guard stored < Self.cloudAnalysisVersion else { return }
        let discarded = await store.resetCloudScans()
        // ⚠️ **捨てた枚数で条件を付けない**（レビュー 14 周目）。`resetCloudScans` は
        // 捨てた枚数に関わらず**必ず再クラスタする**ので、0 枚でもクラスタ ID と構成は変わる
        // ——Dropbox 未接続（よくある状態）だと 0 枚のまま全再クラスタが起き、
        // 控えだけが残って「戻す」が消えたクラスタを名前つき・顔ゼロで作り直していた。
        // 13 周目にここへ入れた修正は、**`if` の 1 段内側**に置いてしまっていた。
        await clearUndoHistory()
        await loadPeople()
        if discarded > 0 {
            Diagnostics.mark("faces: cloud analysis v\(stored)→v\(Self.cloudAnalysisVersion) "
                             + "— discarded \(discarded) cloud scans (local kept)")
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
    struct NameCarryover: Codable {
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

    func saveCarryover(_ carryover: NameCarryover?) {
        guard let carryover else {
            try? FileManager.default.removeItem(at: carryoverURL)
            return
        }
        if let data = try? JSONEncoder().encode(carryover) {
            try? data.write(to: carryoverURL, options: .atomic)
        }
    }


    /// 写真（`PhotoItem.id`：生 localIdentifier / 生 Dropbox パス / "L-…" / "C-…"）に
    /// 写っている人物の表示名。フル画像ビューの People 表示に使う。
    ///
    /// ⚠️ **クラウドの refKey も試す**（レビュー指摘）。ADR-90 以降クラウド写真も顔を検出して
    /// いるのに、ここだけ `"L-"` しか試していなかった。Cloud タブの `DropboxFileItem.id` は
    /// **接頭辞の無い生パス**なので、同じ画面で**顔の黄枠は出るのに人物名は空**という
    /// 食い違いになる（黄枠と長押しの「この人ではない」は `refKeyCandidates` を使っている）。
    public func names(forItemID id: String) async -> [String] {
        for key in Self.refKeyCandidates(for: id) {
            let names = await store.peopleNames(refKey: key, minFaces: minFaces)
            if !names.isEmpty { return names }
        }
        return []
    }

    /// 写真に写っている顔の数（実測）。フル画像ビューの表示用。
    /// 未スキャンは nil＝「まだ数えていない」。`names(forItemID:)` と同じ候補を試す。
    public func faceCount(forItemID id: String) async -> Int? {
        for key in Self.refKeyCandidates(for: id) {
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
    /// 写真が無くなった顔と走査記録を消す（削除・移動・同期対象外）。候補はスキャナと同じ列挙。
    /// 欠けが多すぎる（候補が揃っていない疑い）ときは何もしない。消したら人物一覧を作り直す。
    /// - Returns: 消した顔の数（何もしなかったら 0）。
    @discardableResult
    public func pruneMissingPhotos(candidateRefKeys: [String], knownGone: Set<String> = []) async -> Int {
        guard isFaceModelAvailable, !candidateRefKeys.isEmpty else { return 0 }
        let orphans = await store.repairOrphanFaces()
        if orphans > 0 {
            // 孤児の顔は所属を書き換える＝戻す先が変わっている。
            await clearUndoHistory()
            Diagnostics.mark("faces: repaired \(orphans) orphan face(s) (ADR-187)")
        }
        guard let result = await store.pruneMissingPhotos(existingRefKeys: Set(candidateRefKeys),
                                                          knownGone: knownGone) else {
            Diagnostics.mark("faces: prune skipped — candidates look incomplete")
            return 0
        }
        if result.faces > 0 || result.clusters > 0 {
            // ⚠️ **ここも控えを捨てる**（レビュー 15 周目）。掃除は顔の行を消し、
            // その分をクラスタの重心から引き、空になった行を消す——**戻す先が変わっている**。
            // 捨てないと「戻す」が、消えた顔のぶんを含む古い重心を書き戻し、
            // 掃除で消えた行を**顔ゼロ・重心つき**で復活させる（次のスキャンで二重に数える）。
            // 再クラスタ・版上げ・世代の切り替え・断片の吸収は既にそうしており、
            // **写真が消えたときの掃除だけが漏れていた**。
            await clearUndoHistory()
            Diagnostics.mark("faces: pruned faces=\(result.faces) photos=\(result.photos) emptyClusters=\(result.clusters)")
            await loadPeople()
        }
        return result.faces
    }

    /// 候補のうち未スキャンの枚数（AI 解析画面の「残り」）。候補は `analysisOrderedRefKeys` と同じもの。
    public func pendingScanCount(candidateRefKeys: [String]) async -> Int {
        await store.pendingCount(candidateRefKeys: candidateRefKeys)
    }

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
            // ⚠️ ここも通知する（レビュー 13 周目）。「小さなまとまりを整理」は利用者の操作で
            // 人物の構成を変えるのに、開いたままのグループアルバムが描き直されなかった
            // ——レビューの回答に通知を足したのと**同じ穴**が、1 か所残っていた。
            notifyPeopleEdited()
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
        scan.stop()
        await scan.waitUntilIdle()
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
