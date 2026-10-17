#if canImport(UIKit)
import DropboxCore
import PhotoSourceKit
import SwiftUI

public struct DropboxContentView: View {
    /// 写真と動画を並べるストア（ADR-282）。取得・同期は渡された `DropboxPhotoStore` が持つ。
    @State private var store: DropboxMediaStore

    public init(store: DropboxPhotoStore) {
        _store = State(initialValue: DropboxMediaStore(photos: store))
    }

    public var body: some View {
        PhotoSourceContentView(store: store, title: "Cloud")
    }
}
#endif
