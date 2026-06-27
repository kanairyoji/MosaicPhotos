#if canImport(UIKit)
import CoreLocation
import SwiftUI

/// `PhotoPageView` の 1 ページ分。縦スクロールで写真が上にスライドし、下部に情報パネル（EXIF＋地図）が現れる。
/// 横ページング（TabView）と縦スクロールは軸が直交するため競合しない。
struct FullPhotoView<Store: PhotoStore>: View {
    let store: Store
    let item: Store.Item
    @State private var image: UIImage?
    @State private var failed = false
    /// 「再試行」用。インクリメントすると画像ロード `.task` が再実行される。
    @State private var retryToken = 0
    @State private var exif: PhotoExifInfo?
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var placeName: String?
    @State private var insight: PhotoInsight?
    /// 情報パネルが可視になったか（F）。下までスクロールして初めて EXIF/位置/地名/insight を解決する。
    @State private var infoRequested = false
    @Environment(\.photoInsight) private var photoInsight

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                // LazyVStack：情報パネルは画面下（オフスクリーン）にあり、スクロールで可視化されるまで
                // 構築・onAppear が走らない。ページ送りを画像ロードだけに絞って軽くする（F/E）。
                LazyVStack(spacing: 0) {
                    photo
                        .frame(width: geo.size.width, height: geo.size.height)
                    PhotoInfoPanel(
                        captureDate: item.captureDate,
                        placeName: placeName,
                        coordinate: coordinate,
                        exif: exif,
                        insight: insight
                    )
                    .frame(width: geo.size.width)
                    .onAppear { infoRequested = true }
                }
            }
            .scrollIndicators(.hidden)
            .background(Color.black)
        }
        // フル画像のみ即ロード（取得時にディスクキャッシュ）。ページ送りはこれだけで軽い。
        // T1: 取得 nil（一時的なネットワーク断 -1005 等）は数回リトライし、
        // 全滅したときだけ failed を立てる。読み込み中は "Loading…" を見せる。
        .task(id: ImageKey(id: "\(item.id)", retry: retryToken)) {
            failed = false
            for attempt in 0..<3 {
                if let loaded = await store.fullImage(for: item) {
                    image = loaded
                    return
                }
                if Task.isCancelled { return }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(500)) }
            }
            if !Task.isCancelled { failed = true }
        }
        // 情報パネルが可視になってから EXIF→位置→地名→insight を解決する（F）。
        .task(id: infoRequested) {
            guard infoRequested else { return }
            exif = await store.metadata(for: item)
            let resolved = await store.location(for: item)
            coordinate = resolved
            if let resolved {
                placeName = await PlaceNameResolver.shared.placeName(for: resolved)
            }
            if let photoInsight {
                insight = await photoInsight("\(item.id)")
            }
        }
    }

    @ViewBuilder
    private var photo: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else if failed {
            // T1: 失敗は "not found" 風ではなく、再試行できる控えめな表現にする。
            VStack(spacing: 12) {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Couldn’t load. Tap to retry.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .colorScheme(.dark)
            .contentShape(Rectangle())
            .onTapGesture { retryToken += 1 }
        } else {
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .colorScheme(.dark)
        }
    }

    private struct ImageKey: Equatable {
        let id: String
        let retry: Int
    }
}
#endif
