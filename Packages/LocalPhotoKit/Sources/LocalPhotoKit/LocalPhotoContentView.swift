#if canImport(UIKit)
import LocalPhotoCore
import PhotoSourceKit
import SwiftUI

public struct LocalPhotoContentView: View {
    @State private var store: LocalPhotoStore
    private let title: String

    /// ライブラリ全体を表示する。
    /// - Parameter media: 写真だけか、動画も含めるか（既定値なし＝`LocalPhotoStore.init(media:)`）。
    public init(media: LocalMediaScope, title: String) {
        _store = State(initialValue: LocalPhotoStore(media: media))
        self.title = title
    }

    /// バックアップ収集データから得た localIdentifier リストで写真を表示する。
    /// PHAssetCollection は使わない。
    public init(localIdentifiers: [String], title: String) {
        _store = State(initialValue: LocalPhotoStore(localIdentifiers: localIdentifiers))
        self.title = title
    }

    public var body: some View {
        PhotoSourceContentView(store: store, title: title)
    }
}
#endif
