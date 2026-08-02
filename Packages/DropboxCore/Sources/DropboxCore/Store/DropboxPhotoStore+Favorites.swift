#if canImport(UIKit)
import Foundation

// アプリ側クラウドお気に入り（Dropbox に favorite 概念が無いため、cloudPath 単位でアプリが管理）。
// UserDefaults に cloudPath 集合を永続し、items 構築時に各 DropboxFileItem へ isFavorite を刻印する。
extension DropboxPhotoStore {

    private static let cloudFavoritesKey = "cloudFavoritePaths"

    static func loadCloudFavorites() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: cloudFavoritesKey) ?? [])
    }

    private func persistCloudFavorites() {
        UserDefaults.standard.set(Array(cloudFavoritePaths), forKey: Self.cloudFavoritesKey)
    }

    /// items（キャッシュ由来）へお気に入りを刻印する。お気に入りが無ければ写像コストを避けて素通し。
    func stampFavorites(_ list: [DropboxFileItem]) -> [DropboxFileItem] {
        guard !cloudFavoritePaths.isEmpty else { return list }
        let favs = cloudFavoritePaths
        return list.map { favs.contains($0.path) ? $0.withFavorite(true) : $0 }
    }

    /// クラウドお気に入りの集合（cloudPath）。解析の処理順（お気に入り優先）に使う。
    public var favoriteCloudPaths: Set<String> { cloudFavoritePaths }

    /// Dropbox 写真のお気に入りを付け外しする（アプリ側で永続）。成功で true。
    /// 表示中 items 内の該当アイテムにも刻印し直して、グリッド/情報パネルの★表示へ即反映する。
    public func setFavorite(_ item: DropboxFileItem, _ isFavorite: Bool) async -> Bool {
        if isFavorite { cloudFavoritePaths.insert(item.path) }
        else { cloudFavoritePaths.remove(item.path) }
        persistCloudFavorites()
        updateDisplayedFavorite(path: item.path, isFavorite: isFavorite)
        return true
    }
}
#endif
