#if canImport(UIKit)
import LocalPhotoCore
import Photos
import SwiftUI

public struct LocalThumbnailView: View {
    let asset: PHAsset
    @State private var image: UIImage?

    public init(asset: PHAsset) {
        self.asset = asset
    }

    public var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(uiColor: .secondarySystemBackground)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onAppear { load(size: geo.size) }
        }
    }

    private func load(size: CGSize) {
        guard image == nil else { return }
        let scale = UIScreen.main.scale
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { img, _ in
            Task { @MainActor in
                if let img { image = img }
            }
        }
    }
}
#endif
