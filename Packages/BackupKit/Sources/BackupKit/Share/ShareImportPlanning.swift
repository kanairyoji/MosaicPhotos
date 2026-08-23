import Foundation

/// 受信側の解析取り込み計画（純ロジック・テスト対象）。
/// サイドカーのエントリ（content_hash キー）を、受信側の同期済みクラウド写真
/// （refKey "C-<path>" と content_hash）に突合し、モデル版が一致するセクションだけを
/// 取り込み対象として返す。
public enum ShareImportPlanning {

    /// 受信側 1 写真の参照（同期キャッシュから作る）。
    public struct LocalItem: Sendable {
        public let refKey: String
        public let contentHash: String
        public init(refKey: String, contentHash: String) {
            self.refKey = refKey
            self.contentHash = contentHash
        }
    }

    /// 受信側のモデル版（一致するセクションだけ取り込む）。
    public struct ReceiverVersions: Sendable {
        public let tag: Int
        public let perception: Int
        public let face: Int
        public init(tag: Int, perception: Int, face: Int) {
            self.tag = tag; self.perception = perception; self.face = face
        }
    }

    /// 取り込み対象（refKey 単位・セクション別）。
    public struct Batch: Sendable {
        public var tags: [(refKey: String, entry: ShareSidecar.Entry)] = []
        public var embeddings: [(refKey: String, vectorHalf: Data)] = []
        public var faces: [(refKey: String, faces: [ShareSidecar.Face])] = []
        public init() {}
    }

    /// - Parameters:
    ///   - sidecar: 検証済みサイドカー（`ShareSidecar.decodeValidated` の結果）。
    ///   - localItems: 受信側の同期済み写真（content_hash 付きのもののみ）。
    ///   - versions: 受信側のモデル版。
    /// - Returns: セクション別の取り込みバッチ。同一 content_hash に複数 refKey が
    ///   対応する場合（同じ写真が複数セットにある等）は全 refKey に展開する。
    public static func plan(sidecar: ShareSidecar.File,
                            localItems: [LocalItem],
                            versions: ReceiverVersions) -> Batch {
        var byHash: [String: [String]] = [:]
        for item in localItems {
            byHash[item.contentHash.lowercased(), default: []].append(item.refKey)
        }

        let tagOK = sidecar.versions.tag == versions.tag
        let clipOK = sidecar.versions.perception == versions.perception
        let faceOK = sidecar.versions.face == versions.face

        var batch = Batch()
        for (hash, entry) in sidecar.entries {
            guard let refKeys = byHash[hash] else { continue }
            for refKey in refKeys {
                if tagOK, entry.tags != nil || entry.ocr != nil || entry.human != nil || entry.aes != nil {
                    batch.tags.append((refKey, entry))
                }
                if clipOK, let clip = entry.clip, let data = Data(base64Encoded: clip) {
                    batch.embeddings.append((refKey, data))
                }
                if faceOK, let faces = entry.faces, !faces.isEmpty {
                    batch.faces.append((refKey, faces))
                }
            }
        }
        // 決定的な順序（テスト・ログの安定のため）。
        batch.tags.sort { $0.refKey < $1.refKey }
        batch.embeddings.sort { $0.refKey < $1.refKey }
        batch.faces.sort { $0.refKey < $1.refKey }
        return batch
    }
}
