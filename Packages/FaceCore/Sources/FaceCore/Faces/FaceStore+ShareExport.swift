import CoreGraphics
import Foundation
import SwiftData

/// 家族共有（ADR-112）向けの顔シグナル輸出入。
/// - 輸出: 共有セットのサイドカーへ載せる顔検出結果（bbox・埋め込み・品質・撮影日）を
///   refKey 指定で取り出す。クラスタ ID・人物名は**含めない**（受信側は自分のクラスタに
///   自分で割り当てる）。
/// - 取り込みは既存の `recordScans` を使う（マーカーで二重記録を防ぎ、逐次クラスタリングで
///   受信側の人物へ自然に合流する）。
extension FaceStore {

    /// refKey → 検出顔シグナル。スキャン済みで顔がある写真だけ返す。
    ///
    /// ⚠️ `DetectedFace.refKey` は非インデックスなので、**per-key の predicate 検索は
    /// 1 キーごとに全表走査**になる（数千キー × 数万行で「反映中が終わらない」実障害）。
    /// 少数キーは per-key、多数キーは全件 1 回 fetch → メモリで絞る（`backupRefs` と同じ手筋）。
    func faceSignals(forRefKeys keys: [String]) -> [String: [DetectedFaceSignal]] {
        guard !keys.isEmpty else { return [:] }
        let wanted = Set(keys)
        var out: [String: [DetectedFaceSignal]] = [:]

        func append(_ face: DetectedFace) {
            out[face.refKey, default: []].append(DetectedFaceSignal(
                boundingBox: CGRect(x: face.bx, y: face.by, width: face.bw, height: face.bh),
                embedding: face.embedding,
                quality: Float(face.quality),
                hasSmile: face.hasSmile,
                captureDate: face.captureDate))
        }

        if wanted.count <= 50 {
            for key in wanted {
                let refKey = key
                let faces = (try? modelContext.fetch(FetchDescriptor<DetectedFace>(
                    predicate: #Predicate { $0.refKey == refKey }))) ?? []
                faces.forEach(append)
            }
        } else {
            let all = (try? modelContext.fetch(FetchDescriptor<DetectedFace>())) ?? []
            for face in all where wanted.contains(face.refKey) { append(face) }
        }
        return out
    }

    /// 未スキャンの refKey だけを返す（取り込み前のフィルタ用）。
    func unscannedRefKeys(from keys: [String]) -> [String] {
        guard !keys.isEmpty else { return [] }
        let scanned = scannedRefKeys()
        return keys.filter { !scanned.contains($0) }
    }
}
