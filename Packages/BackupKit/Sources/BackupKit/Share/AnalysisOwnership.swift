import Foundation

/// **解析結果を公開する端末は 1 台にする**ための名乗り（ADR-222 追補）。
///
/// ## なぜ要るか
/// 解析の公開（`<root>/<端末>/Analysis`）は端末フォルダごとに分かれているので、2 台が同時に
/// 公開しても**ファイルが壊れることはない**。壊れない代わりに、**同じ写真の解析が台数ぶん
/// Dropbox に積まれる**——1 台で 100〜200MB（6.8 万枚）なので、3 台なら 500MB 前後を
/// 同じ内容のために使い、上りの通信も台数ぶんかかる。受け取る側も同じ解析を何度も取り込む。
///
/// そこで `<root>/.mosaic-analysis-owner.json` に「今どの端末が公開しているか」を置く。
/// ⚠️ **止めるのではなく、知らせる**。端末を失くした・機種変更したときに公開が永久に止まると
/// 困るので、利用者が「この端末で公開する」を選べば**いつでも引き継げる**。
public enum AnalysisOwnership {

    /// 名乗りの中身（そのまま JSON）。
    public struct Owner: Codable, Equatable, Sendable {
        /// 端末フォルダ名（`BackupDeviceIdentity.currentFolderName()`・人が見る名前）。
        public var deviceFolder: String
        /// **安定 ID**（Keychain・`BackupDeviceIdentity.currentID()`）。
        /// ⚠️ 同一判定はこちらで行う（レビュー指摘）。フォルダ名は端末名の変更や機種変更の復元で
        /// 変わるので、名前で比べると**自分の名乗りを他人と誤認**して公開が止まる。
        /// 旧い名乗り（ID 無し）との互換のため optional。
        public var deviceID: String?
        /// 人が読む名前（Dropbox 上で見分ける補助）。
        public var deviceName: String
        /// 名乗った日時。
        public var claimedAt: Date
        /// 最後に公開できた日時（引き継ぎの判断材料＝「この端末、もう 3 か月動いていない」）。
        public var lastPublishedAt: Date?
        /// 最後に公開した時点の写真枚数（同上）。
        public var photoCount: Int?

        public init(deviceFolder: String, deviceID: String? = nil, deviceName: String,
                    claimedAt: Date, lastPublishedAt: Date? = nil, photoCount: Int? = nil) {
            self.deviceFolder = deviceFolder
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.claimedAt = claimedAt
            self.lastPublishedAt = lastPublishedAt
            self.photoCount = photoCount
        }
    }

    /// この端末が公開してよいか。
    public enum Decision: Equatable, Sendable {
        /// まだ誰も名乗っていない（名乗って公開する）。
        case unclaimed
        /// 自分が名乗っている。
        case ours
        /// **別の端末が名乗っている**。公開せず、設定画面で知らせる。
        case otherDevice(Owner)
        /// 別の端末が名乗っていたが、利用者が「この端末で公開する」を選んだ（引き継ぐ）。
        case takenOver(Owner)
    }

    /// 判断（純ロジック・テスト対象）。
    /// - Parameters:
    ///   - remote: Dropbox 上の名乗り（無ければ nil）。
    ///   - myDeviceFolder: この端末のフォルダ名。
    ///   - acknowledgedDeviceFolder: 利用者が「この端末で公開する」を選んだときの、
    ///     **そのとき名乗っていた端末**のフォルダ名。
    public static func decide(remote: Owner?, myDeviceFolder: String, myDeviceID: String? = nil,
                              acknowledgedDeviceFolder: String?) -> Decision {
        guard let remote else { return .unclaimed }
        // まず**安定 ID**で見る（端末名を変えても自分は自分）。無い名乗り（旧版）は名前で見る。
        if let myDeviceID, let remoteID = remote.deviceID {
            if remoteID.caseInsensitiveCompare(myDeviceID) == .orderedSame { return .ours }
        } else if remote.deviceFolder.caseInsensitiveCompare(myDeviceFolder) == .orderedSame {
            return .ours
        }
        // ⚠️ 承諾は**その相手に対してだけ**効く。承諾したあと 3 台目が名乗ったら、もう一度尋ねる
        // （「一度 OK したから以後ずっと黙る」だと、増えた端末に気づけない）。
        if let acknowledgedDeviceFolder,
           acknowledgedDeviceFolder.caseInsensitiveCompare(remote.deviceFolder) == .orderedSame {
            return .takenOver(remote)
        }
        return .otherDevice(remote)
    }

    /// 公開してよい判断か。
    public static func allowsPublishing(_ decision: Decision) -> Bool {
        switch decision {
        case .unclaimed, .ours, .takenOver: return true
        case .otherDevice: return false
        }
    }

    /// 名乗りを更新する（公開できた後に呼ぶ）。前の名乗りが他端末でも、引き継いだら自分になる。
    /// - Parameter published: この回に**実際に公開できたか**。
    ///   ⚠️ 公開の前に名乗る回（引き継ぎ・初回）でも「最後に公開できた日」を今にすると、
    ///   1 枚も上げられない端末まで「生きている」ように見え、引き継ぎの判断材料が死ぬ（レビュー指摘）。
    public static func claim(myDeviceFolder: String, myDeviceID: String? = nil, myDeviceName: String,
                             previous: Owner?, now: Date, photoCount: Int?,
                             published: Bool) -> Owner {
        let mine: Bool
        if let myDeviceID, let previousID = previous?.deviceID {
            mine = previousID.caseInsensitiveCompare(myDeviceID) == .orderedSame
        } else {
            mine = previous?.deviceFolder.caseInsensitiveCompare(myDeviceFolder) == .orderedSame
        }
        return Owner(deviceFolder: myDeviceFolder, deviceID: myDeviceID, deviceName: myDeviceName,
                     claimedAt: mine ? (previous?.claimedAt ?? now) : now,
                     lastPublishedAt: published ? now : (mine ? previous?.lastPublishedAt : nil),
                     photoCount: published ? photoCount : (mine ? previous?.photoCount : nil))
    }

    public static func decode(_ data: Data) -> Owner? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Owner.self, from: data)
    }

    public static func encode(_ owner: Owner) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try? encoder.encode(owner)
    }
}
