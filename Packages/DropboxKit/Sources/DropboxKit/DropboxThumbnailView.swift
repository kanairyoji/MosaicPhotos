#if canImport(UIKit)
import DropboxCore
import SwiftUI

public struct DropboxThumbnailView: View {
    let item: DropboxFileItem
    let store: DropboxPhotoStore
    @State private var image: UIImage?

    public init(item: DropboxFileItem, store: DropboxPhotoStore) {
        self.item = item
        self.store = store
    }

    public var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(uiColor: .secondarySystemBackground)
            }
        }
        .task(id: item.id) {
            image = nil
            image = await store.thumbnail(for: item)
        }
    }
}
#endif
