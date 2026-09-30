import Foundation
import PerceptionCore
import SwiftData

/// **クラウドの顔の撮影日を後から埋める**（ADR-218）。
///
/// クラウド写真の撮影日時は、Dropbox に 1 枚ずつ問い合わせて少しずつ分かっていく（ADR-201）。
/// 顔のスキャンはそれを待たないので、先にスキャンした顔は撮影日が空のまま記録される。
/// 撮影日は時期グループ（ADR-61）と赤ちゃんの時期の決まりの材料なので、分かった分を埋め直す。
///
/// ⚠️ 顔 1 件ずつ引かない（ADR-119）。読み出しは「空の顔を集める」「書き込む」の 2 回だけ。
extension FaceStore {

    /// 撮影日が空の**クラウドの**顔がある写真の path（重複なし・並びは決定的）。
    func cloudPathsMissingCaptureDate() -> [String] {
        var d = FetchDescriptor<DetectedFace>(predicate: #Predicate { $0.captureDate == nil })
        d.propertiesToFetch = [\.refKey]
        var paths = Set<String>()
        for face in countedFetchOptional(d) ?? [] {
            if let path = PhotoRef.decode(face.refKey)?.cloudPath { paths.insert(path) }
        }
        return paths.sorted()
    }

    /// path → 撮影日時 を、撮影日が空のクラウドの顔へ書き込む。
    /// - Returns: 埋めた顔の数。
    @discardableResult
    func fillCloudCaptureDates(_ datesByPath: [String: Date]) -> Int {
        guard !datesByPath.isEmpty else { return 0 }
        let d = FetchDescriptor<DetectedFace>(predicate: #Predicate { $0.captureDate == nil })
        var filled = 0
        for face in countedFetchOptional(d) ?? [] {
            guard let path = PhotoRef.decode(face.refKey)?.cloudPath,
                  let date = datesByPath[path] else { continue }
            face.captureDate = date
            filled += 1
        }
        if filled > 0 { try? modelContext.save() }
        return filled
    }

    /// テスト用: 写真ごとの撮影日（顔が 1 つでもあれば）。
    func captureDatesByRefKeyForTesting() -> [String: Date?] {
        var out: [String: Date?] = [:]
        for face in countedFetchOptional(FetchDescriptor<DetectedFace>()) ?? [] {
            out[face.refKey] = face.captureDate
        }
        return out
    }
}

/// 「撮影日の埋め直しを走らせてよいか」の純ロジック（ADR-243）。
///
/// ⚠️ 実機ログ diagnostics-101 で、成果ゼロの全走査が毎時走っていた。答えが変わり得る入力は
/// 「クラウド側の EXIF の知識」と「スキャン済み写真の数」の 2 つだけなので、
/// **どちらも動いていなければ走らせない**。
/// ⚠️ 判断を実時間や DB から切り離してここに置く——実機で 5 時間ぶん同じ行が並んでから
/// 気づいた種類なので、規則そのものをテストで固定する。
public enum CaptureDateFillGate {

    /// 前回と同じ入力なら飛ばしてよい。
    /// - Parameters:
    ///   - progress: いまのクラウド EXIF 探索の進み具合。
    ///   - scanned: いまのスキャン済み写真の数。
    ///   - lastProgress: 前回走らせたときの `progress`（nil＝一度も走らせていない）。
    ///   - lastScanned: 前回走らせたときの `scanned`。
    public static func canSkip(progress: Int, scanned: Int,
                               lastProgress: Int?, lastScanned: Int?) -> Bool {
        // ⚠️ **一度も走らせていないなら必ず走る**。nil を「同じ」と読むと初回から飛ばしてしまう。
        guard let lastProgress, let lastScanned else { return false }
        return progress == lastProgress && scanned == lastScanned
    }
}
