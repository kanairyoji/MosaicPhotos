import CoreGraphics
import Foundation

/// ピープル（顔クラスタ＝1 人物）の表示用値型。`@Model` を actor 外へ出さないための Sendable 値。
public struct PersonInfo: Identifiable, Sendable, Equatable {
    public let clusterID: Int
    public let name: String?
    public let count: Int
    /// 代表顔の写真キー（refKey）と顔矩形（アバター切り抜き用・Vision 正規化座標）。
    public let coverRefKey: String?
    public let coverBoundingBox: CGRect?
    /// このクラスタに属する写真キー（重複排除済み・代表度＝顔の多い写真順ではなく登場順）。
    public let memberRefKeys: [String]
    /// 2 階層で複数クラスタを束ねた人物か（ADR-61）。true なら「束ねを解除」を提示できる。
    public var isGrouped: Bool = false
    /// 一覧での通し番号（1 始まり）。**表示専用**で、同一性は `clusterID` が持つ。
    ///
    /// ⚠️ 以前は `clusterID + 1` をそのまま出していたが、クラスタ ID は再クラスタのたびに
    /// 既存最大 ID の続きから振られる（`minimumNextID`）ため単調に増え、人物が 400 人でも
    /// 「Person 4985」のような番号が出る。**人数と誤読される**ので通し番号に変えた（ADR-68）。
    public var displayIndex: Int = 0

    public var id: Int { clusterID }
    /// 名前未設定なら "Person N"（N は一覧での通し番号＝内部 ID ではない）。
    public var displayName: String {
        name ?? "Person \(displayIndex > 0 ? displayIndex : clusterID + 1)"
    }

    /// 代表写真の選択候補（クラスタ内の顔・写真ごと1つ）。ピッカー表示用。
    public struct Face: Identifiable, Sendable, Equatable {
        public let faceID: String
        public let refKey: String
        public let boundingBox: CGRect
        public var id: String { faceID }
        public init(faceID: String, refKey: String, boundingBox: CGRect) {
            self.faceID = faceID
            self.refKey = refKey
            self.boundingBox = boundingBox
        }
    }

    public init(clusterID: Int, name: String?, count: Int,
                coverRefKey: String?, coverBoundingBox: CGRect?, memberRefKeys: [String],
                isGrouped: Bool = false) {
        self.clusterID = clusterID
        self.name = name
        self.count = count
        self.coverRefKey = coverRefKey
        self.coverBoundingBox = coverBoundingBox
        self.memberRefKeys = memberRefKeys
        self.isGrouped = isGrouped
    }
}
