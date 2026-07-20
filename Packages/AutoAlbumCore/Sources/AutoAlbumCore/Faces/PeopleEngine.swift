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
    /// 直近のスキャン候補（reset 後の再スキャンに使う）。
    @ObservationIgnored private var lastCandidates: [String] = []
    @ObservationIgnored private var lastAllowSimulator = false

    /// 「人物」とみなす最小顔数。
    private let minFaces = 3

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
        let store = await Task.detached(priority: .userInitiated) { FaceStore() }.value
        return PeopleEngine(faceProvider: faceProvider,
                            favoriteRefKeysProvider: favoriteRefKeysProvider,
                            store: store)
    }

    /// 顔モデルが同梱され利用可能か（未同梱ならピープルは無効＝空表示）。
    public var isFaceModelAvailable: Bool { faceProvider?.isAvailable ?? false }

    /// 永続済みのクラスタからピープル一覧を読み込む。
    /// 代表写真はユーザー選択（保存済み）→ お気に入り写真 → 認識した写真の先頭、の順で決まる。
    public func loadPeople() async {
        let favorites = await favoriteRefKeysProvider?() ?? []
        people = await store.peopleClusters(minFaces: minFaces, favoriteRefKeys: favorites)
        isLoaded = true
        Diagnostics.mark("faces: people=\(people.count) (>= \(minFaces) faces, favs=\(favorites.count))")
    }

    /// 端末写真の refKey 候補（"L-…"）の未スキャン分を背景で処理する。重複起動は防ぐ。
    /// `allowSimulator` が true なら（Developer Options のデバッグトグル）シミュレータでも走らせる。
    public func startScan(candidateRefKeys: [String], allowSimulator: Bool = false) {
        guard isFaceModelAvailable else { isLoaded = true; return }
        lastCandidates = candidateRefKeys
        lastAllowSimulator = allowSimulator
        guard scanTask == nil else { return }
        scanTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            self.isScanning = true
            BackgroundActivityMonitor.shared.isScanningFaces = true
            await self.tagger.scan(
                candidateRefKeys: candidateRefKeys,
                allowSimulator: allowSimulator,
                shouldPause: {
                    // 重い処理の共通方針（電源接続＋低電力OFF＋一定時間アイドル＋生成との
                    // 相互排他）は BackgroundYield.heavyShouldPause に一元化。
                    BackgroundYield.heavyShouldPause()
                },
                onProgress: {
                    self.remaining = $0
                    BackgroundActivityMonitor.shared.faceScanRemaining = $0
                },
                onBatch: { [weak self] in await self?.loadPeople() })
            self.isScanning = false
            BackgroundActivityMonitor.shared.isScanningFaces = false
            BackgroundActivityMonitor.shared.faceScanRemaining = 0
            self.scanTask = nil
        }
    }

    /// クラスタに名前を付ける／消す。
    public func rename(clusterID: Int, name: String?) async {
        await store.rename(clusterID: clusterID, name: name)
        await loadPeople()
    }

    /// 人物 src を人物 dst に統合する（同一人物が別々に認識されたときの修正）。
    /// src の顔は全て dst へ移り、src は消える。名前・代表写真は dst を優先。
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
        scanTask?.cancel()
        scanTask = nil
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
}
