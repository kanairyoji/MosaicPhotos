import Foundation

/// 共有セットの解析サイドカー（`<セット>/.mosaic-share/analysis-v1.json`）のフォーマットと
/// エンコード/デコード・防御的検証（純ロジック・テスト対象）。
///
/// - エントリのキーは **Dropbox content_hash**（送信者と受信者で refKey が異なるため、
///   パスにも refKey にも依存しない結合キーを使う・ADR-112）。
/// - 受信側は**自分のモデル版と一致するセクションだけ**取り込む（不一致は自前解析に任せる）。
/// - 別デバイスが書いた外部入力なので、受信側は `validate` で上限・次元・有限性を検査してから使う。
public enum ShareSidecar {

    /// サイドカーの置き場所（セットフォルダからの相対）。
    public static let subfolderName = ".mosaic-share"
    public static let fileName = "analysis-v1.json"
    public static func sidecarPath(setFolderPath: String) -> String {
        "\(setFolderPath)/\(subfolderName)/\(fileName)"
    }

    public static let formatVersion = 1

    /// 人物名の最大長（外部入力なので必ず切り詰める）。
    static let maxNameLength = 64

    // MARK: - DTO

    /// 顔 1 個分（`DetectedFaceSignal` 相当・CGRect 非依存の素の数値）。
    public struct Face: Codable, Sendable, Equatable {
        /// bbox（Vision 準拠の正規化座標・原点左下）。
        public var x: Double
        public var y: Double
        public var w: Double
        public var h: Double
        /// identity 埋め込み（Float16・base64）。
        public var e: String
        public var q: Float
        /// 笑顔（未計測 nil）。
        public var s: Bool?
        /// 撮影日（epoch 秒・未取得 nil）。
        public var d: Double?
        /// 人物名（ADR-167）。**送信側の設定で載せないことも選べる**ので、常に nil であり得る。
        /// 受信側は名前を「提案」として扱う——自分が既に付けた名前は上書きしない。
        public var n: String?

        public init(x: Double, y: Double, w: Double, h: Double,
                    e: String, q: Float, s: Bool? = nil, d: Double? = nil, n: String? = nil) {
            self.x = x; self.y = y; self.w = w; self.h = h
            self.e = e; self.q = q; self.s = s; self.d = d; self.n = n
        }
    }

    /// 写真 1 枚分の解析。
    public struct Entry: Codable, Sendable, Equatable {
        public var tags: [String]?
        public var ocr: String?
        public var human: Int?
        public var aes: Double?
        /// CLIP 埋め込み（Float16 512 次元・base64）。
        public var clip: String?
        public var faces: [Face]?

        public init(tags: [String]? = nil, ocr: String? = nil, human: Int? = nil,
                    aes: Double? = nil, clip: String? = nil, faces: [Face]? = nil) {
            self.tags = tags; self.ocr = ocr; self.human = human
            self.aes = aes; self.clip = clip; self.faces = faces
        }
    }

    /// 各セクションのモデル版（受信側は一致するセクションのみ取り込む）。
    public struct Versions: Codable, Sendable, Equatable {
        public var tag: Int?
        public var perception: Int?
        public var face: Int?
        public init(tag: Int? = nil, perception: Int? = nil, face: Int? = nil) {
            self.tag = tag; self.perception = perception; self.face = face
        }
    }

    public struct File: Codable, Sendable, Equatable {
        public var formatVersion: Int
        public var versions: Versions
        /// content_hash → 解析エントリ。
        public var entries: [String: Entry]

        public init(formatVersion: Int = ShareSidecar.formatVersion,
                    versions: Versions, entries: [String: Entry]) {
            self.formatVersion = formatVersion
            self.versions = versions
            self.entries = entries
        }
    }

    // MARK: - 上限（防御的検証）

    public static let maxFileBytes = 64 * 1024 * 1024
    public static let maxEntries = 20_000
    public static let maxTagsPerEntry = 64
    public static let maxTagLength = 64
    public static let maxOcrLength = 4_096
    public static let maxFacesPerEntry = 32
    /// CLIP / 顔埋め込みの Float16 バイト長（512 次元 × 2 バイト）。
    public static let embeddingByteCount = 1_024
    /// 撮影日として現実的な epoch 秒の範囲（1900-01-01 〜 2100-01-01）。
    static let plausibleEpochRange: ClosedRange<Double> = -2_208_988_800 ... 4_102_444_800

    // MARK: - Encode / Decode

    /// 決定的エンコード（sortedKeys）＝内容が同じなら同一バイト列。
    /// チェックサム比較で「変化なしなら再アップロードしない」を成立させる。
    public static func encode(_ file: File) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(file)
    }

    /// デコード＋防御的検証。壊れた・過大な・次元不正のエントリは**黙って捨てる**
    /// （クラッシュも汚染もさせず、欠けた分は受信側の自前解析に任せる）。
    /// ファイル自体が不正なら nil。
    public static func decodeValidated(_ data: Data) -> File? {
        guard data.count <= maxFileBytes else { return nil }
        guard var file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        guard file.formatVersion == formatVersion else { return nil }

        var cleaned: [String: Entry] = [:]
        for (hash, entry) in file.entries {
            guard cleaned.count < maxEntries else { break }
            // content_hash は 64 桁 hex（Dropbox 仕様）。形式外のキーは捨てる。
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { continue }
            if let valid = validate(entry) { cleaned[hash.lowercased()] = valid }
        }
        file.entries = cleaned
        return file
    }

    /// 1 エントリの検証。全セクションが落ちたら nil。
    static func validate(_ entry: Entry) -> Entry? {
        var out = Entry()
        if let tags = entry.tags {
            let valid = tags.prefix(maxTagsPerEntry)
                .filter { !$0.isEmpty && $0.count <= maxTagLength }
            if !valid.isEmpty { out.tags = Array(valid) }
        }
        if let ocr = entry.ocr, !ocr.isEmpty {
            out.ocr = String(ocr.prefix(maxOcrLength))
        }
        if let human = entry.human, (0...500).contains(human) { out.human = human }
        if let aes = entry.aes, aes.isFinite, (-1.0...1.0).contains(aes) { out.aes = aes }
        if let clip = entry.clip, validEmbedding(clip) { out.clip = clip }
        if let faces = entry.faces {
            let valid = faces.prefix(maxFacesPerEntry).compactMap { face -> Face? in
                guard validEmbedding(face.e),
                      [face.x, face.y, face.w, face.h].allSatisfy({ $0.isFinite && (-1.0...2.0).contains($0) }),
                      face.q.isFinite, (0...1).contains(face.q)
                else { return nil }
                // ⚠️ 撮影日も検証する。NaN/巨大値をそのまま Date にすると、人物の時期分割で
                // 日付ソートの strict weak ordering が壊れる（Swift の sort が未定義動作・
                // デバッグ版では precondition 失敗）。範囲外は「日付なし」に落とす。
                var cleaned = face
                if let d = face.d, !(d.isFinite && Self.plausibleEpochRange.contains(d)) {
                    cleaned.d = nil
                }
                // 人物名も**外部入力**。長さを切り詰め、空白だけの名前は落とす
                // （画面や検索へそのまま出る値なので、素通しにしない）。
                if let name = cleaned.n {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    cleaned.n = trimmed.isEmpty ? nil : String(trimmed.prefix(maxNameLength))
                }
                return cleaned
            }
            if !valid.isEmpty { out.faces = Array(valid) }
        }
        let empty = out.tags == nil && out.ocr == nil && out.human == nil
            && out.aes == nil && out.clip == nil && out.faces == nil
        return empty ? nil : out
    }

    /// base64 埋め込みの検証（復号可能・Float16 512 次元ちょうど・全要素有限）。
    static func validEmbedding(_ base64: String) -> Bool {
        guard let data = Data(base64Encoded: base64), data.count == embeddingByteCount else {
            return false
        }
        return data.withUnsafeBytes { raw in
            raw.bindMemory(to: UInt16.self).allSatisfy { bits in
                // Float16 の Inf/NaN（指数部が全 1）を弾く。
                (bits & 0x7C00) != 0x7C00
            }
        }
    }

    /// 内容チェックサム（FNV-1a 64bit・再アップロード省略の比較用）。
    public static func checksum(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
