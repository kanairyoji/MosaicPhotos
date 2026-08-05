import Foundation

/// 顔認識の品質スナップショット（ADR-68）。
///
/// データセット計測（`face-accuracy.md`）は**正解ラベルがある**から精度を出せるが、
/// 実機のライブラリには正解が無いので「純度 0.97」のような値は原理的に出せない。
/// そこで**正解なしでも測れる代理指標**を集める:
/// - 分裂の量: 人物数・単発クラスタ数・**統合候補ペア数**（＝同一人物らしいのに別々のまま残っている数）
/// - 破れてはいけない不変条件: **同一写真に同一人物が2回**（1枚の写真に同じ人は1回しか写らない）
public struct FaceQualityReport: Sendable, Equatable {
    public var scannedPhotos: Int
    public var faces: Int
    /// どのクラスタにも属していない顔（品質フロア未満・マージンで弾かれた等）。
    public var unassignedFaces: Int

    public var clusters: Int
    /// ピープルに出る人物（メンバー数 `minFaces` 以上）。
    public var people: Int
    /// 1 顔だけのクラスタ（分裂の主な残骸）。
    public var singletons: Int
    /// 成熟クラスタ（サイズ免除の人数判定に使う母数）。
    public var maturePeople: Int
    public var namedPeople: Int
    public var largestCluster: Int

    public var threshold: Float
    /// いまサイズ免除（ADR-68）が効く状態か（成熟クラスタ数が上限未満か）。
    public var sizeExemptionActive: Bool

    /// **統合候補ペア数**: 重心類似がレビュー帯域以上で、共起 notSame でもないクラスタ対の数。
    /// 「まだ畳めていない分裂」の実測。0 に近いほど良い。
    public var mergeCandidatePairs: Int
    /// 計算を打ち切ったか（クラスタが多すぎる場合。O(N²) を実機で走らせないため）。
    public var mergeCandidateTruncated: Bool

    /// **同一写真違反**: 1 枚の写真に同じクラスタの顔が 2 つ以上ある件数（(写真, 人物) の組）。
    /// 割り当て時は cannot-link で防いでいるが、**統合（レビュー・手動）は検査していない**ため
    /// ここで事後検出する。0 が正常。
    public var samePhotoViolations: Int
    /// 違反に関わる写真の数。
    public var samePhotoViolationPhotos: Int

    public var corrections: Int

    public init(scannedPhotos: Int = 0, faces: Int = 0, unassignedFaces: Int = 0,
                clusters: Int = 0, people: Int = 0, singletons: Int = 0,
                maturePeople: Int = 0, namedPeople: Int = 0, largestCluster: Int = 0,
                threshold: Float = 0, sizeExemptionActive: Bool = false,
                mergeCandidatePairs: Int = 0, mergeCandidateTruncated: Bool = false,
                samePhotoViolations: Int = 0, samePhotoViolationPhotos: Int = 0,
                corrections: Int = 0) {
        self.scannedPhotos = scannedPhotos
        self.faces = faces
        self.unassignedFaces = unassignedFaces
        self.clusters = clusters
        self.people = people
        self.singletons = singletons
        self.maturePeople = maturePeople
        self.namedPeople = namedPeople
        self.largestCluster = largestCluster
        self.threshold = threshold
        self.sizeExemptionActive = sizeExemptionActive
        self.mergeCandidatePairs = mergeCandidatePairs
        self.mergeCandidateTruncated = mergeCandidateTruncated
        self.samePhotoViolations = samePhotoViolations
        self.samePhotoViolationPhotos = samePhotoViolationPhotos
        self.corrections = corrections
    }

    /// 診断ログ 1 行（実機で Mac 無しに追える形）。
    public var logLine: String {
        var s = "faces/quality: photos=\(scannedPhotos) faces=\(faces) unassigned=\(unassignedFaces) "
            + "clusters=\(clusters) people=\(people) named=\(namedPeople) singletons=\(singletons) "
            + "mature=\(maturePeople) largest=\(largestCluster) "
            + String(format: "thr=%.2f ", threshold)
            + "exempt=\(sizeExemptionActive ? "on" : "off") "
            + "mergeCandidates=\(mergeCandidatePairs)\(mergeCandidateTruncated ? "+" : "") "
            + "samePhotoViolations=\(samePhotoViolations)"
        if samePhotoViolations > 0 { s += " (photos=\(samePhotoViolationPhotos))" }
        s += " corrections=\(corrections)"
        return s
    }
}
