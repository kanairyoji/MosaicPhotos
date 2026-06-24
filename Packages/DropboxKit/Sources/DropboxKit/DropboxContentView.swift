#if canImport(UIKit)
import DropboxCore
import PhotoSourceKit
import SwiftUI

public struct DropboxContentView: View {
    let store: DropboxPhotoStore

    public init(store: DropboxPhotoStore) {
        self.store = store
    }

    public var body: some View {
        PhotoSourceContentView(store: store, title: "Cloud")
    }
}
#endif
