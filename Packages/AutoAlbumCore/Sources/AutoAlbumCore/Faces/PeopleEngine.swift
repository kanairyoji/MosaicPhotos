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
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// 直近のスキャン候補（reset 後の再スキャンに使う）。
    @ObservationIgnored private var lastCandidates: [String] = []
    @ObservationIgnored private var lastAllowSimulator = false

    /// 「人物」とみなす最小顔数。
    private let minFaces = 3

    public init(faceProvider: FacePerceptionProvider?) {
        let store = FaceStore()
        self.store = store
        self.faceProvider = faceProvider
        self.tagger = FaceTagger(store: store, provider: faceProvider)
    }

    /// 顔モデルが同梱され利用可能か（未同梱ならピープルは無効＝空表示）。
    public var isFaceModelAvailable: Bool { faceProvider?.isAvailable ?? false }

    /// 永続済みのクラスタからピープル一覧を読み込む。
    public func loadPeople() async {
        people = await store.peopleClusters(minFaces: minFaces)
        isLoaded = true
        Diagnostics.mark("faces: people=\(people.count) (>= \(minFaces) faces)")
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
                    // 顔認識は重いので、**電源に接続されているときだけ**動かす（電池では動かさない）。
                    // 低電力モード中も止める。加えて操作中・メモリ圧迫中・クラウド取得中は譲る。
                    !PowerStateMonitor.shared.isOnPower
                        || PowerStateMonitor.shared.isLowPowerMode
                        || MemoryPressureMonitor.shared.isUnderPressure
                        || BackgroundActivityMonitor.shared.isViewingPhoto
                        || BackgroundActivityMonitor.shared.fullImageBusy
                        || BackgroundActivityMonitor.shared.cloudThumbnailBusy
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

    /// 代表写真の選択候補（クラスタ内の顔・写真ごと）。
    public func coverCandidates(clusterID: Int) async -> [PersonInfo.Face] {
        await store.facesForCluster(clusterID: clusterID)
    }

    /// 代表写真（トップに出す顔）を選ぶ。
    public func setCover(clusterID: Int, faceID: String) async {
        await store.setCover(clusterID: clusterID, faceID: faceID)
        await loadPeople()
    }

    /// 全消去して再スキャンする（直近の候補があれば自動で再開）。
    public func reset() async {
        scanTask?.cancel()
        scanTask = nil
        await store.reset()
        await loadPeople()
        Diagnostics.mark("faces: reset — rescanning \(lastCandidates.count) candidates")
        if !lastCandidates.isEmpty {
            startScan(candidateRefKeys: lastCandidates, allowSimulator: lastAllowSimulator)
        }
    }
}
