import AutoAlbumCore
import DropboxKit
import Foundation
import MobileCLIPKit
import MosaicSupport
import UIKit

/// クラウド顔スキャンの**歩留まり実測**ランナー（ADR-89・Developer Options から実行）。
///
/// 目的: 「クラウドの埋め込み到達率が低いのは 256px サムネに対する顔 48px 下限のせい」という
/// **推定を実データで検証**し、採用すべきサムネサイズと顔ピクセル下限を数字で決める。
///
/// 測り方（重要）: サイズごとに何度もダウンロードしない。**計測サイズで 1 回だけ検出**し、
/// 各顔の正規化矩形から「サイズ S での顔ピクセル数 = 正規化辺 × S」を算術で出す
/// （`FaceYieldMeasurement`）。1 枚の取得から全サイズの歩留まりが得られる。
///
/// 標本: 撮影日で層化抽出する。子どもの成長のように**時期で写り方が変わる**データでは
/// 先頭から N 枚では偏るため（`stratifiedSample`）。
@MainActor
@Observable
final class FaceYieldMeasurementRunner {
    /// 進捗表示用（"123 / 5000" 等）。空なら未実行。
    private(set) var status = ""
    private(set) var isRunning = false
    /// 直近の集計結果（画面表示用・全文はファイルへ）。
    private(set) var summary = ""

    private var task: Task<Void, Never>?

    /// 計測に使うサムネサイズ（Dropbox 指定）。これで取得して検出し、他サイズは算術で換算する。
    /// w1024h768 は「検討する最大サイズ」＝ここで見えない顔は、どのサイズでも使えない。
    static let measurementAPISize = "w1024h768"
    /// 換算して評価するサイズ（正方の一辺）。現行 256 と候補 640 / 1024。
    static let evaluatedSizes = [256, 640, 1024]

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        status = "cancelled"
    }

    /// 計測を実行する。`sampleSize` は取得枚数（通信量 ≒ 枚数 × 約 130KB）。
    func run(dropboxStore: DropboxPhotoStore, sampleSize: Int) {
        guard !isRunning else { return }
        isRunning = true
        summary = ""
        status = "sampling…"

        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false }

            // 1. 撮影日で層化抽出（時期の偏りを避ける）。
            if dropboxStore.items.isEmpty { await dropboxStore.loadItems() }
            let items = dropboxStore.items.map { (id: $0.path, date: $0.captureDate) }
            let paths = FaceYieldMeasurement.stratifiedSample(items, sampleSize: sampleSize)
            guard !paths.isEmpty else {
                self.status = "no cloud photos"
                return
            }
            Diagnostics.mark("faces/yield: start — sample=\(paths.count) of \(items.count) "
                             + "size=\(Self.measurementAPISize)")

            // 2. 1 枚ずつ取得して検出（取得は次の 1 枚を先読み＝通信と推論を重ねる・ADR-83/84）。
            let adapter = FacePerceptionAdapter()
            var observations: [FaceYieldMeasurement.FaceObservation] = []
            var photosWithFace = 0
            var fetched = 0, failed = 0, bytes = 0
            let started = Date()

            var ahead: Task<Data?, Never>? = nil
            for (index, path) in paths.enumerated() {
                if Task.isCancelled { break }
                let data: Data?
                if let ahead { data = await ahead.value } else {
                    data = await dropboxStore.measurementThumbnailData(
                        path: path, apiSize: Self.measurementAPISize)
                }
                // 次の 1 枚の取得を、この 1 枚の検出と重ねる。
                ahead = index + 1 < paths.count
                    ? Task { [next = paths[index + 1]] in
                        await dropboxStore.measurementThumbnailData(
                            path: next, apiSize: Self.measurementAPISize)
                      }
                    : nil

                guard let data, let image = UIImage(data: data),
                      let cg = orientationNormalizedCGImage(image) else {
                    failed += 1
                    continue
                }
                fetched += 1
                bytes += data.count
                let faces = await adapter.observeFacesForMeasurement(in: cg)
                if !faces.isEmpty { photosWithFace += 1 }
                observations.append(contentsOf: faces)

                if index % 25 == 0 {
                    self.status = "\(index + 1) / \(paths.count)"
                    await Task.yield()
                }
            }

            // 3. 集計してログとファイルへ。
            let elapsed = Date().timeIntervalSince(started)
            let avgKB = fetched > 0 ? Double(bytes) / Double(fetched) / 1024 : 0
            var text = FaceYieldMeasurement.report(
                photos: fetched, photosWithFace: photosWithFace,
                observations: observations, sizes: Self.evaluatedSizes,
                minConfidence: FaceQualityGate.minDetectionConfidence)
            text += String(format: "\n  fetched=%d failed=%d avg=%.0fKB/photo elapsed=%.0fs (%.2fs/photo)",
                           fetched, failed, avgKB, elapsed,
                           fetched > 0 ? elapsed / Double(fetched) : 0)
            // 実運用での通信量見積り（全クラウド写真を同サイズで取った場合）。
            let totalGB = Double(items.count) * avgKB / 1024 / 1024
            text += String(format: "\n  projected: %d photos × %.0fKB = %.1fGB at %@",
                           items.count, avgKB, totalGB, Self.measurementAPISize)

            self.summary = text
            for line in text.split(separator: "\n") { Diagnostics.mark(String(line)) }
            self.status = Task.isCancelled ? "cancelled (partial)" : "done"
            Self.writeReport(text)
        }
    }

    /// 全文を Caches へ書く（診断ログの共有シートとは別に、表を崩さず持ち出せるように）。
    private static func writeReport(_ text: String) {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("face-yield-report.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
