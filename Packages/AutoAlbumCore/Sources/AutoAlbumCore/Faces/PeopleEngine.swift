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
        guard scanTask == nil else { return }
        scanTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            self.isScanning = true
            BackgroundActivityMonitor.shared.isScanningFaces = true
            await self.tagger.scan(
                candidateRefKeys: candidateRefKeys,
                allowSimulator: allowSimulator,
                shouldPause: {
                    MemoryPressureMonitor.shared.isUnderPressure
                        || BackgroundActivityMonitor.shared.isViewingPhoto
                        || BackgroundActivityMonitor.shared.fullImageBusy
                        || BackgroundActivityMonitor.shared.cloudThumbnailBusy
                        || !PowerStateMonitor.shared.backgroundAllowed()
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

    /// 全消去して再スキャンできるようにする。
    public func reset() async {
        scanTask?.cancel()
        scanTask = nil
        await store.reset()
        await loadPeople()
    }
}
