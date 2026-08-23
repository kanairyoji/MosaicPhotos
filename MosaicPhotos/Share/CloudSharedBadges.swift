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

        for set in sets {
            guard let key = set.sourceKey.flatMap(ShareSourceKey.init) else {
                legacyNames.insert(set.name)
                continue
            }
            switch key {
            case .group(let id):   badges.groups.insert(id)
            case .person(let id):  badges.persons.insert(id)
            case .album(let id):   badges.albums.insert(id)
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
