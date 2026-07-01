import Foundation
import MosaicSupport

/// 未スキャンの写真に対して顔検出＋埋め込み＋クラスタリングをバックグラウンドで増分実行する。
/// CLIP の `PhotoTagger` と同じく**小バッチ＋休止＋譲り**で trickle 処理し、端末・UI を圧迫しない。
@MainActor
final class FaceTagger {
    private let store: FaceStore
    private let provider: FacePerceptionProvider?
    private var isRunning = false
    private static let log = LogChannel(subsystem: "com.mosaicphotos.AutoAlbum", label: "FaceTagger")

    init(store: FaceStore, provider: FacePerceptionProvider?) {
        self.store = store
        self.provider = provider
    }

    /// `candidateRefKeys`（端末写真の refKey 群）のうち未スキャン分を処理する。
    /// 進捗ごと・完了時に `onBatch` を呼ぶ（ピープル一覧の再読込に使う）。
    func scan(candidateRefKeys: [String],
              batchSize: Int = 8,
              betweenBatchNs: UInt64 = 2_500_000_000,
              allowSimulator: Bool = false,
              shouldPause: @MainActor () -> Bool = { false },
              onProgress: @MainActor (Int) -> Void = { _ in },
              onBatch: () async -> Void) async {
        guard let provider, provider.isAvailable else {
            Self.log.info("face scan: skipped — face model not bundled / provider unavailable")
            Diagnostics.mark("faces: skipped — model not bundled/unavailable")
            return
        }
        // 顔モデルはシミュレータでは cpuOnly で重いため既定でスキップ（実機で計測）。
        // ただし Developer Options のデバッグトグル（allowSimulator）が ON なら走らせる。
        #if targetEnvironment(simulator)
        if !allowSimulator {
            Self.log.info("face scan: skipped on simulator (enable in Developer Options to debug)")
            Diagnostics.mark("faces: skipped on simulator — enable 'Face scan in Simulator' to run")
            return
        }
        Diagnostics.mark("faces: running on simulator (debug・cpuOnly＝slow)")
        #endif
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false; onProgress(0) }

        let done = await store.scannedRefKeys()
        let todo = candidateRefKeys.filter { !done.contains($0) }
        Diagnostics.mark("faces: start — candidates=\(candidateRefKeys.count) already=\(done.count) todo=\(todo.count)")
        guard !todo.isEmpty else {
            Diagnostics.mark("faces: nothing to scan (all done)")
            return
        }
        Self.log.info("face scan: start — \(todo.count) photos to scan (batch \(batchSize))")
        onProgress(todo.count)

        var index = 0
        var processed = 0
        var facesFound = 0
        var batchNo = 0
        while index < todo.count, !Task.isCancelled {
            while shouldPause() && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if Task.isCancelled { break }

            let end = min(index + batchSize, todo.count)
            let batch = Array(todo[index..<end])
            index = end

            let signals = await provider.detectFaces(refKeys: batch)
            for refKey in batch {
                let faces = signals[refKey] ?? []
                facesFound += faces.count
                await store.recordScan(refKey: refKey, faces: faces)
            }
            processed += batch.count
            onProgress(max(0, todo.count - processed))

            batchNo += 1
            if batchNo % 8 == 0 {
                Diagnostics.mark("faces: \(processed)/\(todo.count) scanned, faces=\(facesFound)")
                await onBatch()   // 一覧をときどき更新
            }
            try? await Task.sleep(nanoseconds: betweenBatchNs)
        }
        Self.log.info("face scan: finished — \(processed) photos")
        Diagnostics.mark("faces: finished — scanned=\(processed) faces=\(facesFound)")
        await onBatch()
    }
}
