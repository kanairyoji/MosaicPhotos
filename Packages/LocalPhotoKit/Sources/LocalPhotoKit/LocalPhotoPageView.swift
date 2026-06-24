#if canImport(UIKit)
import LocalPhotoCore
import Photos
import SwiftUI

public struct LocalPhotoPageView: View {
    let assets: [PHAsset]
    @State var currentIndex: Int

    public init(assets: [PHAsset], currentIndex: Int) {
        self.assets = assets
        self.currentIndex = currentIndex
    }

    public var body: some View {
        TabView(selection: $currentIndex) {
            ForEach(assets.indices, id: \.self) { index in
                LocalFullPhotoView(asset: assets[index])
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color.black)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let date = assets[currentIndex].creationDate {
                    Text(date, style: .date)
                        .font(.subheadline)
                }
            }
        }
    }
}

private struct LocalFullPhotoView: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onAppear { load() }
    }

    private func load() {
        guard image == nil else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { img, _ in
            Task { @MainActor in
                if let img { image = img }
            }
        }
    }
}
#endif
