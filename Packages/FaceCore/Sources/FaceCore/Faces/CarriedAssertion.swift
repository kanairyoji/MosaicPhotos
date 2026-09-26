import Foundation

/// 再スキャン・モデル世代の切り替えを跨いで持ち越す「**ユーザーの表明**」1 人ぶん（ADR-232）。
///
/// ## なぜ名前だけでは足りなかったか
/// clusterID は再スキャンで振り直される。そこで ADR-51 は「**写真の重なり**で旧人物と新人物を
/// 突き合わせて名前を戻す」仕組みを入れた——が、持ち越していたのは**名前だけ**だった。
/// 名前と同じ重みの表明が 2 つ、黙って消えていた:
///
/// - **束ね**（ADR-61 の `personGroupID`）: 成長で複数クラスタに分かれた子供を 1 人にまとめた指定。
///   再スキャン後はほどけて、一覧に同じ子が何人も並ぶ。
/// - **ピープルグループの所属**（家族・チーム）: グループは clusterID で人物を指しているので、
///   旧 ID が消えると `PeopleGroupInfo.resolve` がそのメンバーを落とす
///   ＝**家族グループから人が黙って消える**。
///
/// どちらも「利用者がわざわざ手で作ったもの」で、機械が作り直せない。ADR-130/132/134 の原則
/// （ユーザーが表明したものを最優先で守る）はここにも及ぶ。名前と同じ経路で運ぶ。
public struct CarriedAssertion: Codable, Sendable, Equatable {

    /// 付けた名前。**無名でも**束ね・グループ所属があれば持ち越す（表明はしているので）。
    public var name: String?
    /// 束ねの札（ADR-61）。同じ札だったクラスタは、新しい世代でも同じ 1 人に束ね直す。
    public var personGroupID: Int?
    /// 属していたピープルグループの id（UUID は世代を跨いで変わらない）。
    public var peopleGroupIDs: [UUID]
    /// 突き合わせの鍵。写真は再スキャンしても変わらないので安定キーになる。
    public var memberRefKeys: [String]

    public init(name: String?, personGroupID: Int? = nil,
                peopleGroupIDs: [UUID] = [], memberRefKeys: [String]) {
        self.name = name
        self.personGroupID = personGroupID
        self.peopleGroupIDs = peopleGroupIDs
        self.memberRefKeys = memberRefKeys
    }

    /// 名前・束ね・グループ所属のどれかがあるか（無ければ持ち越す意味がない）。
    /// `FaceSeedBuilder.ClusterRef.isAsserted` と同じ語（同じ「表明」の判定）。
    ///
    /// ⚠️ **`== false`**（名前があって、かつ空でない）。`name` は `String?` なので
    /// `== true` と書くと「空文字が入っている」を意味し、判定が丸ごと裏返る
    /// ——レビュー中にここを一度間違えた（`isEmpty` からの言い換えで符号を落とした）。
    /// `FaceSeedBuilder.ClusterRef.isNamed` も同じ形。
    public var isAsserted: Bool {
        (name?.isEmpty == false) || personGroupID != nil || !peopleGroupIDs.isEmpty
    }

    /// 控え（戻り待ち）と新しいスナップショットを重ねる（ADR-232・純ロジック）。
    ///
    /// ⚠️ **新しいスナップショットを先に置く**。上限で切るときに落ちるのは後ろなので、
    /// 順番が「どちらを諦めるか」を決めてしまう。戻り待ちは既に一度戻せなかったもの、
    /// スナップショットは**今まさに消そうとしている**ものなので、後者を優先する。
    /// ⚠️ 重複判定は `memberRefKeys` を**並べてから**比べる。元が `Set` なので、
    /// アプリを開き直すと同じ写真の集合でも並びが変わる（Swift の Set の走査順はプロセスごと）。
    /// 並べずに比べると、開き直したあとの再スキャンで同じ表明がもう 1 件積まれる。
    /// - Parameters:
    ///   - snapshot: これから消すストアから取った表明。
    ///   - pending: ディスクに残っている戻り待ち（ストアには居ない人たち）。
    ///   - limit: 積む上限（1 件あたり最大 500 の refKey を持つのでファイルが大きくなる）。
    public static func merged(snapshot: [CarriedAssertion], pending: [CarriedAssertion],
                             limit: Int) -> [CarriedAssertion] {
        var seen = Set<String>()
        return (snapshot + pending)
            .filter { seen.insert($0.identity).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// 重複判定キー（同じ表明を 2 度積まない）。
    var identity: String {
        "\(name ?? "")|\(personGroupID.map(String.init) ?? "")|"
            + "\(peopleGroupIDs.map(\.uuidString).sorted().joined(separator: ","))|"
            + memberRefKeys.sorted().joined(separator: ",")
    }

    /// 束ねの札を**世代を跨いで**持ち越すときの値。
    ///
    /// 札はただの目印で、値そのものに意味はない（同じ札なら同じ 1 人）。ただし `linkClusters` は
    /// 新しい札に「束ねたクラスタ ID の最小値」＝**0 以上**を使う。旧世代の札をそのまま持ち込むと、
    /// 再スキャンで生まれた無関係な束ねと**同じ値になり得る**＝別人が 1 人に束ねられる。
    /// 負の側を持ち越し専用の並びにして、ぶつからないようにする。
    /// 既に負なら（前の世代で持ち越した札）そのまま——何度持ち越しても値が動かない。
    public static func carriedPersonGroupID(_ old: Int) -> Int { old < 0 ? old : -(old + 1) }

    // MARK: - 旧形式との互換
    //
    // ディスクには `{"name":…,"memberRefKeys":[…]}` だけの版が残っている（名前しか持ち越して
    // いなかった頃のファイル）。読めなくなると**持ち越し待ちの名前が丸ごと消える**ので、
    // 足りない鍵は既定値で埋める。

    private enum CodingKeys: String, CodingKey {
        case name, personGroupID, peopleGroupIDs, memberRefKeys
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        personGroupID = try c.decodeIfPresent(Int.self, forKey: .personGroupID)
        peopleGroupIDs = try c.decodeIfPresent([UUID].self, forKey: .peopleGroupIDs) ?? []
        memberRefKeys = try c.decodeIfPresent([String].self, forKey: .memberRefKeys) ?? []
    }
}
