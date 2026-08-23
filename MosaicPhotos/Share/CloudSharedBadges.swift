import AutoAlbumCore
import BackupKit
import Foundation

/// 「この人物 / グループ / アルバムをクラウド共有している」を示すバッジの対象 ID 集合。
///
/// ⚠️ ビューの計算プロパティにしない（body 評価のたびに数千人物・数万アイテムを
/// 走査してしまう）。`shareEngine.sets` が変わったときにだけ `resolve` で作り直し、
/// `@State` に保持する（規約: 巨大コレクションを MainActor に通さない／ADR-95）。
struct CloudSharedBadges: Equatable {
    var groups: Set<UUID> = []
    var persons: Set<Int> = []
    var albums: Set<String> = []

    /// 共有セットの作成元（`ShareSourceKey`）から逆引きする。
    ///
    /// 旧セットは `sourceKey` を持たない（後から追加した項目）ため、**名前の一致**で
    /// フォールバック判定する。実機で「共有しているのにバッジが出ない」となった対処。
    static func resolve(sets: [ShareSyncEngine.SetSummary],
                        people: [PersonInfo],
                        groups peopleGroups: [PeopleGroupInfo],
                        albums: [AutoAlbumInfo]) -> CloudSharedBadges {
        var badges = CloudSharedBadges()
        var legacyNames: Set<String> = []

        // 現存する ID の集合（解決できたかの判定に使う）。
        let liveGroupIDs = Set(peopleGroups.map(\.id))
        let livePersonIDs = Set(people.map(\.clusterID))
        let liveAlbumIDs = Set(albums.map(\.id))

        for set in sets {
            guard let key = set.sourceKey.flatMap(ShareSourceKey.init) else {
                legacyNames.insert(set.name)   // 旧セット（sourceKey 追加前）
                continue
            }
            // ⚠️ 作成元が**現存しない**セットも名前一致にフォールバックする。
            // 例: ピープルグループを解除して同じ名前で作り直すと UUID が変わるため、
            // ID 照合だけではバッジが出ない（実フィードバック）。
            switch key {
            case .group(let id):
                if liveGroupIDs.contains(id) { badges.groups.insert(id) }
                else { legacyNames.insert(set.name) }
            case .person(let id):
                if livePersonIDs.contains(id) { badges.persons.insert(id) }
                else { legacyNames.insert(set.name) }
            case .album(let id):
                if liveAlbumIDs.contains(id) { badges.albums.insert(id) }
                else { legacyNames.insert(set.name) }
            }
        }
        guard !legacyNames.isEmpty else { return badges }

        for group in peopleGroups where legacyNames.contains(group.name) {
            badges.groups.insert(group.id)
        }
        for person in people where legacyNames.contains(person.displayName) {
            badges.persons.insert(person.clusterID)
        }
        for album in albums where legacyNames.contains(album.placesLabel) {
            badges.albums.insert(album.id)
        }
        return badges
    }
}
