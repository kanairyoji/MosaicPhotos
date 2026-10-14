import AutoAlbumCore
import BackupKit
import CoreGraphics
import Foundation

/// 受信した解析データ 1 つを、各ストアへ渡す形（タグ・埋め込み・顔・撮影日）に組み立てる純ロジック。
///
/// 以前は `SharedAnalysisImporter.runIfNeeded` の中の `Task.detached` のクロージャに直書きで、
/// アプリ層のテストが届かなかった。⚠️ オフメインで呼ぶ（6.8 万件規模の突合と base64 デコード）。
nonisolated enum ShareImportPreparation {

    /// 1 つの解析データから組み立てたもの。
    struct Pieces: Sendable {
        let tags: [(refKey: String, info: PhotoSenseInfo)]
        let embeddings: [(refKey: String, vectorHalf: Data)]
        let faces: [(refKey: String, faces: [DetectedFaceSignal])]
        /// Dropbox パス（小文字）→ 撮影日（ADR-199・表示の並び替え用）。
        let captureDates: [String: Date]
        /// 解析データの全エントリが手元の写真に突合できたか（rev 記録の可否）。
        let fullyMatched: Bool
    }

    /// 突合の索引（1 回だけ作って解析データ間で使い回す）。
    struct Index: Sendable {
        let byHash: [String: [String]]
        let hashes: Set<String>
    }

    /// 突合の対象は**手元のクラウド写真すべて**（ADR-222）。家族フォルダの外にも相手の写真はある
    /// ——鍵は content_hash（同じ中身＝同じ写真）なので置き場所で絞らない。
    static func index(hashesByPath: [String: String]) -> Index {
        let localItems = hashesByPath.map { path, hash in
            ShareImportPlanning.LocalItem(refKey: PhotoRef.cloud(path).encoded, contentHash: hash)
        }
        let index = ShareImportPlanning.index(of: localItems)
        return Index(byHash: index, hashes: Set(index.keys))
    }

    static func pieces(of file: ShareAnalysisData.File, index: Index,
                       versions: ShareImportPlanning.ReceiverVersions) -> Pieces {
        let batch = ShareImportPlanning.plan(analysisData: file, index: index.byHash, versions: versions)
        let tags = batch.tags.map {
            (refKey: $0.refKey,
             info: PhotoSenseInfo(tags: $0.entry.tags ?? [], ocrText: $0.entry.ocr,
                                  humanCount: $0.entry.human, aesthetic: $0.entry.aes))
        }
        var faces: [(refKey: String, faces: [DetectedFaceSignal])] = []
        for (refKey, rawFaces) in batch.faces {
            let signals = rawFaces.compactMap { face -> DetectedFaceSignal? in
                guard let embedding = Data(base64Encoded: face.e) else { return nil }
                return DetectedFaceSignal(
                    boundingBox: CGRect(x: face.x, y: face.y, width: face.w, height: face.h),
                    embedding: embedding, quality: face.q, hasSmile: face.s,
                    captureDate: face.d.map { Date(timeIntervalSince1970: $0) },
                    personName: face.n)
            }
            if !signals.isEmpty { faces.append((refKey, signals)) }
        }
        // まだ同期されていない写真が残っている解析データは rev を記録しない
        // （次回の実行で残りを取り込む。取り込みは既存レコードをスキップするので冪等）。
        let fullyMatched = file.entries.keys.allSatisfy { index.hashes.contains($0) }
        // 撮影日は refKey（"C-<path>"）で来るので、表示側が引く形（パス小文字）へ戻す。
        var captureDates: [String: Date] = [:]
        for (refKey, date) in batch.captureDates {
            guard case .cloud(let path)? = PhotoRef.decode(refKey) else { continue }
            captureDates[path.lowercased()] = date
        }
        return Pieces(tags: tags, embeddings: batch.embeddings, faces: faces,
                      captureDates: captureDates, fullyMatched: fullyMatched)
    }

    /// 「取り込み済み」を記録してよいか。
    /// ⚠️ 記録するのは、**全部コミットできたとき**だけ。保存に失敗した回に記録すると、
    /// 同じ解析データは以後ダウンロードされず、欠けた解析結果を再取得できない（レビュー指摘）。
    /// 未同期の写真が残っている場合（fullyMatched=false）も同様に記録しない。
    /// 撮影日の**保存に失敗した**回は見送る（次回やり直せる）。
    static func shouldMarkImported(fullyMatched: Bool, committed: Bool, datesLanded: Bool) -> Bool {
        fullyMatched && committed && datesLanded
    }
}
