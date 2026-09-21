import Foundation

/// **連写・バーストの顔を「同じ人の一続き」として繋ぐ**（純ロジック・テスト対象・ADR-211）。
///
/// ## なぜ要るか
/// 連写は数秒のあいだ同じ人が同じ位置に写る。ところが**そのうち何枚かは必ずぶれる**——
/// ぶれた顔は品質フロア（0.40）未満になり、埋め込みだけを頼りに最寄り人物へ賭ける
/// 第2パス（ADR-66）に回される。実ライブラリでは顔の約半数がフロア未満で、
/// 第2パスの正解率は FG-NET 実測で 88%＝**表示される顔の 12% は別人のアルバムに載る**。
///
/// しかし連写には埋め込みより強い証拠がある: **同じ写真群の同じ位置に写っている**。
/// 0.3 秒前の同じ場所にいた顔は、ぶれていようが横を向いていようが同じ人である。
/// この証拠を使えば、埋め込みが当てにならない顔ほど確実に繋がる。
///
/// ## 安全側の設計（3 つ）
/// 1. **重心には決して足さない**。繋ぐのは所属（membership）だけで、`sum`/`count` は動かさない。
///    間違えても人物の重心は汚れず、1 枚外せば直る（ADR-133/137 と同じ代償の小ささ）。
/// 2. **既にある割り当ては動かさない**。埋め込みで入った顔を「位置が違う」と追い出したりしない。
///    足すだけなので、ここを入れても既存の判定は 1 つも変わらない。
/// 3. **矛盾したら何もしない**。1 本の連なり（トラック）の中で人物の証拠が割れていたら、
///    そのトラックは繋がない。同じ写真に居合わせたトラックどうしが同じ人物を指していたら、
///    それは**同一写真 cannot-link の破れ**なので両方とも無効にする。
///
/// ## 同一写真 cannot-link の連鎖（ADR-54 の拡張）
/// 「1 枚の写真に同じ人は 1 回しか写らない」は写真ごとの制約だった。連写では、
/// **1 枚でも居合わせた 2 本のトラックは、その連写のあいだずっと別人**である。
/// 制約が 1 枚から連写全体へ伝播する＝埋め込みが曖昧な顔ほど強く守られる。
public enum TemporalLinking {

    /// 正規化座標（原点左下・0…1）の矩形。`CGRect` を使わないのは、この判断を
    /// Foundation だけで完結させて macOS の高速テストで回すため。
    public struct Box: Sendable, Equatable {
        public let x: Double, y: Double, width: Double, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }

        var area: Double { max(0, width) * max(0, height) }

        /// 交差÷和集合。どちらかが退化（面積 0）なら 0。
        public func iou(_ other: Box) -> Double {
            let x0 = max(x, other.x), y0 = max(y, other.y)
            let x1 = min(x + width, other.x + other.width)
            let y1 = min(y + height, other.y + other.height)
            let intersection = max(0, x1 - x0) * max(0, y1 - y0)
            let union = area + other.area - intersection
            guard union > 0 else { return 0 }
            return intersection / union
        }
    }

    public struct Face: Sendable, Equatable {
        public let faceID: String
        public let refKey: String
        public let captureDate: Date?
        public let box: Box
        /// 現在の割り当て（未割当は `FaceClustering.unassigned`）。
        public let clusterID: Int
        /// 重心（sum/count）を作った顔か。**この顔だけが人物の証拠になる**——
        /// membership だけで入った顔（第2パス・前回の時系列連結）を証拠にすると、
        /// 推測が推測を裏づける循環になる。
        public let contributes: Bool

        public init(faceID: String, refKey: String, captureDate: Date?, box: Box,
                    clusterID: Int, contributes: Bool) {
            self.faceID = faceID
            self.refKey = refKey
            self.captureDate = captureDate
            self.box = box
            self.clusterID = clusterID
            self.contributes = contributes
        }
    }

    /// 1 人ぶんの連なり（写真をまたいで同じ位置を追ったもの）。
    public struct Track: Sendable, Equatable {
        public let faceIDs: [String]
        public let refKeys: [String]
        /// 証拠が一致した人物（無ければ nil）。
        public let anchorClusterID: Int?
        public init(faceIDs: [String], refKeys: [String], anchorClusterID: Int?) {
            self.faceIDs = faceIDs
            self.refKeys = refKeys
            self.anchorClusterID = anchorClusterID
        }
    }

    public struct Link: Sendable, Equatable {
        public let faceID: String
        public let clusterID: Int
        public init(faceID: String, clusterID: Int) {
            self.faceID = faceID
            self.clusterID = clusterID
        }
    }

    public struct Plan: Sendable, Equatable {
        public var links: [Link] = []
        public var tracks: [Track] = []
        /// 証拠が割れて繋がなかったトラックの数（＝「走って 0 件」と「走っていない」を分ける・ADR-157）。
        public var conflicts: Int = 0
    }

    /// 連写とみなす写真間の最大間隔。
    ///
    /// ⚠️ **短くする**。長くすると「同じ場所に立った別人」（記念撮影の交代）を繋ぐ。
    /// バーストは 0.1 秒間隔、連写の指押しでも 1 秒以内なので 3 秒で十分に覆う。
    public static let defaultMaxGap: TimeInterval = 3

    /// 同じ人とみなす矩形の重なり。
    ///
    /// ⚠️ **高くする**。0.5 は「ほぼ同じ位置・同じ大きさ」で、隣に立つ人とは普通は重ならない
    /// （顔どうしが 50% 重なるのは、顔が重なって写っている場合だけ）。
    public static let defaultMinIoU: Double = 0.5

    /// - Parameters:
    ///   - isBlocked: (faceID, clusterID) → 繋いではいけないか（負例・ユーザーの「別人」記録）。
    public static func plan(faces: [Face],
                            maxGap: TimeInterval = defaultMaxGap,
                            minIoU: Double = defaultMinIoU,
                            isBlocked: (String, Int) -> Bool = { _, _ in false }) -> Plan {
        var plan = Plan()
        // 撮影日が無い顔は連写の判断に使えない（時刻が分からなければ隣かどうかも分からない）。
        let dated = faces.filter { $0.captureDate != nil }
        guard dated.count >= 2 else { return plan }

        // 写真単位にまとめる。⚠️ 並べ替えは (撮影日, refKey) で**完全に決定的**にする
        // ——同時刻の写真が辞書順で入れ替わると、その晩ごとに違うトラックができる。
        var byPhoto: [String: [Face]] = [:]
        for face in dated { byPhoto[face.refKey, default: []].append(face) }
        var photos: [Photo] = []
        photos.reserveCapacity(byPhoto.count)
        for (refKey, group) in byPhoto {
            let date: Date = group.compactMap(\.captureDate).min() ?? .distantPast
            photos.append(Photo(refKey: refKey, faces: group.sorted { $0.faceID < $1.faceID },
                                date: date))
        }
        photos.sort { $0.date != $1.date ? $0.date < $1.date : $0.refKey < $1.refKey }

        // 連写のかたまりへ切る。
        var session: [Photo] = []
        for photo in photos {
            if let last = session.last, photo.date.timeIntervalSince(last.date) > maxGap {
                appendSession(session, minIoU: minIoU, isBlocked: isBlocked, into: &plan)
                session = []
            }
            session.append(photo)
        }
        appendSession(session, minIoU: minIoU, isBlocked: isBlocked, into: &plan)
        plan.links.sort { $0.faceID < $1.faceID }
        return plan
    }

    /// 写真 1 枚ぶん（同じ refKey の顔と、その撮影日）。
    struct Photo {
        let refKey: String
        let faces: [Face]
        let date: Date
    }

    /// 1 つの連写を処理して計画へ足す。
    private static func appendSession(_ session: [Photo],
                                      minIoU: Double,
                                      isBlocked: (String, Int) -> Bool,
                                      into plan: inout Plan) {
        guard session.count >= 2 else { return }

        /// 構築中のトラック。
        struct Building {
            var lastBox: Box
            var faces: [Face]
        }
        var building: [Building] = []
        // 同じ写真に居合わせたトラックの組（cannot-link の連鎖の材料）。
        var coOccurring: Set<Pair> = []

        for photo in session {
            // (顔, トラック) の重なりを全部出し、**重なりの大きい順に**貪欲に繋ぐ。
            // 同値は faceID → トラック番号で割って決定的にする。
            var pairs: [(faceIndex: Int, trackIndex: Int, iou: Double)] = []
            for (faceIndex, face) in photo.faces.enumerated() {
                for (trackIndex, track) in building.enumerated() {
                    let iou = track.lastBox.iou(face.box)
                    if iou >= minIoU { pairs.append((faceIndex, trackIndex, iou)) }
                }
            }
            pairs.sort {
                if $0.iou != $1.iou { return $0.iou > $1.iou }
                if $0.faceIndex != $1.faceIndex { return $0.faceIndex < $1.faceIndex }
                return $0.trackIndex < $1.trackIndex
            }
            var usedFace = Set<Int>(), usedTrack = Set<Int>()
            var trackOfFace: [Int: Int] = [:]
            for pair in pairs where !usedFace.contains(pair.faceIndex)
                && !usedTrack.contains(pair.trackIndex) {
                usedFace.insert(pair.faceIndex)
                usedTrack.insert(pair.trackIndex)
                trackOfFace[pair.faceIndex] = pair.trackIndex
            }
            // 繋がらなかった顔は新しいトラックの頭になる。
            for (faceIndex, face) in photo.faces.enumerated() where !usedFace.contains(faceIndex) {
                building.append(Building(lastBox: face.box, faces: []))
                trackOfFace[faceIndex] = building.count - 1
            }
            for (faceIndex, face) in photo.faces.enumerated() {
                guard let trackIndex = trackOfFace[faceIndex] else { continue }
                building[trackIndex].lastBox = face.box
                building[trackIndex].faces.append(face)
            }
            // この写真に居合わせたトラックどうしを記録する（同一写真＝別人）。
            let present = trackOfFace.values.sorted()
            for i in present.indices {
                for j in (i + 1)..<present.count where present[i] != present[j] {
                    coOccurring.insert(Pair(present[i], present[j]))
                }
            }
        }

        // 各トラックの証拠（重心を作った顔の人物）が一致しているか。
        var anchors: [Int: Int] = [:]
        for (index, track) in building.enumerated() {
            let claimed = Set(track.faces.filter { $0.contributes && $0.clusterID >= 0 }
                              .map(\.clusterID))
            if claimed.count == 1, let only = claimed.first { anchors[index] = only }
            else if claimed.count > 1 { plan.conflicts += 1 }
        }
        // ⚠️ **同一写真 cannot-link の連鎖**。1 枚でも居合わせた 2 本が同じ人物を指したら、
        // どちらかが必ず間違っている——どちらか分からないので**両方の証拠を捨てる**。
        for pair in coOccurring {
            guard let a = anchors[pair.low], let b = anchors[pair.high], a == b else { continue }
            anchors[pair.low] = nil
            anchors[pair.high] = nil
            plan.conflicts += 1
        }

        // ⚠️ 占有は**その写真に居る顔ぜんぶ**で見る（自分のトラックの中だけでは足りない）。
        // 隣のトラックが membership だけでその人物に入っていることがあり、そこへ足すと
        // 1 枚の写真に同じ人が 2 回いる状態を**こちらが作ってしまう**。
        var occupancy: [String: Set<Int>] = [:]
        for photo in session {
            for face in photo.faces where face.clusterID >= 0 {
                occupancy[face.refKey, default: []].insert(face.clusterID)
            }
        }

        for (index, track) in building.enumerated() {
            let anchor = anchors[index]
            plan.tracks.append(Track(faceIDs: track.faces.map(\.faceID),
                                     refKeys: track.faces.map(\.refKey),
                                     anchorClusterID: anchor))
            guard let anchor else { continue }
            for face in track.faces where face.clusterID < 0 {
                guard !(occupancy[face.refKey]?.contains(anchor) ?? false),
                      !isBlocked(face.faceID, anchor) else { continue }
                plan.links.append(Link(faceID: face.faceID, clusterID: anchor))
                occupancy[face.refKey, default: []].insert(anchor)
            }
        }
    }

    /// 順序に依存しないトラック対のキー。
    private struct Pair: Hashable {
        let low: Int, high: Int
        init(_ a: Int, _ b: Int) { low = min(a, b); high = max(a, b) }
    }
}
