import Foundation

/// フォルダ名アルバム（Dropbox パスから推測）の生成をまとめた協調オブジェクト。
/// 状態（公開 pathAlbums）はエンジンが持ち、本オブジェクトは store を更新して結果を返す。
@MainActor
final class PathAlbumGenerator {
    private let store: AutoAlbumStore
    private let cloudProvider: CloudPhotoProvider?

    init(store: AutoAlbumStore, cloudProvider: CloudPhotoProvider?) {
        self.store = store
        self.cloudProvider = cloudProvider
    }

    /// 軽量・地名解決なし：Dropbox のメタデータ（パス）だけで生成。グルーピングはバックグラウンドで行う。
    /// 戻り値 = 新しい pathAlbums。設定 OFF・ルール無し・provider 無しのときは空にして store も空に。
    func generateFast() async -> [AutoAlbumInfo] {
        let rules = Self.rules()
        guard Self.enabled, !rules.isEmpty, let cloudProvider else {
            await store.replaceAlbums(forStrategy: PathAlbumStrategy.strategyID, with: [])
            return []
        }
        let metas = await cloudProvider.cloudPhotos()
        let infos = await Task.detached(priority: .utility) {
            computePathAlbums(metas: metas, rules: rules)
        }.value
        await store.replaceAlbums(forStrategy: PathAlbumStrategy.strategyID, with: infos)
        return infos
    }

    /// フル生成用：エンリッチ済み全写真から（お気に入り/横長などでカバーを賢く選べる）。保存は呼び出し側。
    func makeFromEnriched(_ allEnriched: [EnrichedPhoto]) -> [AutoAlbumInfo] {
        let rules = Self.rules()
        guard Self.enabled, !rules.isEmpty else { return [] }
        return PathAlbumStrategy(rules: rules).makeAlbums(fromCloud: allEnriched).map(pathInfo(from:))
    }

    // MARK: - Settings

    private static var enabled: Bool {
        UserDefaults.standard.bool(forKey: AutoAlbumSettingsKeys.pathAlbumsEnabled)
    }

    /// 設定（JSON）からフォルダ名アルバムの抽出ルールを読む。
    private static func rules() -> [PathAlbumRule] {
        guard let json = UserDefaults.standard.string(forKey: AutoAlbumSettingsKeys.pathAlbumRules),
              let data = json.data(using: .utf8),
              let rules = try? JSONDecoder().decode([PathAlbumRule].self, from: data)
        else { return [] }
        return rules
    }
}

/// Dropbox メタデータ（パス）だけからフォルダ名アルバムを作る純ロジック（地名解決不要・バックグラウンド可）。
func computePathAlbums(metas: [CloudPhotoMeta], rules: [PathAlbumRule]) -> [AutoAlbumInfo] {
    let photos = metas.map { meta in
        EnrichedPhoto(id: PhotoRef.cloud(meta.path).encoded, captureDate: meta.captureDate,
                      latitude: meta.latitude, longitude: meta.longitude, placeName: nil)
    }
    return PathAlbumStrategy(rules: rules).makeAlbums(fromCloud: photos).map(pathInfo(from:))
}

/// フォルダ名アルバムの下書き → 表示用 AutoAlbumInfo。id はフォルダ名ベースで日付が重なっても衝突しない。
func pathInfo(from draft: GeneratedAlbumDraft) -> AutoAlbumInfo {
    let name = draft.placeName ?? "Album"
    return AutoAlbumInfo(
        id: "\(PathAlbumStrategy.strategyID):\(name)", strategyID: PathAlbumStrategy.strategyID,
        title: name, placeName: name, places: draft.places, country: nil, people: draft.people,
        startDate: draft.startDate, endDate: draft.endDate, coverRef: draft.coverRef,
        memberRefs: draft.memberRefs, photoCount: draft.photoCount,
        representativeDate: draft.representativeDate, latitude: draft.latitude, longitude: draft.longitude)
}
