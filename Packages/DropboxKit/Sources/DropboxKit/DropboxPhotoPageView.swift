#if canImport(UIKit)
import DropboxCore
import SwiftUI

public struct DropboxPhotoPageView: View {
    let items: [DropboxFileItem]
    @State var currentIndex: Int
    let store: DropboxPhotoStore

    public init(items: [DropboxFileItem], currentIndex: Int, store: DropboxPhotoStore) {
        self.items = items
        self.currentIndex = currentIndex
        self.store = store
    }

    public var body: some View {
        TabView(selection: $currentIndex) {
            ForEach(items.indices, id: \.self) { index in
                DropboxFullPhotoView(item: items[index], store: store)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color.black)
        .ignoresSafeArea()
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(items[currentIndex].nameWithoutExtension)
    }
}

// MARK: - Full photo view

private struct DropboxFullPhotoView: View {
    let item: DropboxFileItem
    let store: DropboxPhotoStore
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                Text("Unable to display.")
                    .foregroundStyle(.secondary)
                    .colorScheme(.dark)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .task(id: item.id) {
            image = nil
            failed = false
            if let loaded = await store.fullImage(for: item) {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}
#endif
