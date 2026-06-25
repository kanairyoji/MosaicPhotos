#if canImport(UIKit)
import CoreLocation
import MapKit
import SwiftUI

/// Generic full-screen paging view. Swipe horizontally to navigate between items.
/// Toolbar shows `displayTitle` when available, otherwise formats `captureDate`.
public struct PhotoPageView<Store: PhotoStore>: View {
    let store: Store
    /// 現在のページを **item.id** で保持する（C/E）。`Array(items.enumerated())` の
    /// 6.7万件タプル配列を作らず、`ForEach(store.items)` を直接回す。
    @State private var currentID: Store.Item.ID

    public init(store: Store, startID: Store.Item.ID) {
        self.store = store
        self._currentID = State(initialValue: startID)
    }

    private var currentItem: Store.Item? {
        store.items.first { $0.id == currentID }
    }

    public var body: some View {
        TabView(selection: $currentID) {
            ForEach(store.items) { item in
                FullPhotoView(store: store, item: item)
                    .tag(item.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color.black)
        .ignoresSafeArea()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let item = currentItem {
                    if let title = item.displayTitle {
                        Text(title).font(.subheadline)
                    } else if let date = item.captureDate {
                        Text(DisplayDate.ymd(date)).font(.subheadline)
                    }
                }
            }
        }
        // Pre-fetch the next page as soon as the page view opens, so photos are
        // ready before the user swipes near the end.
        .task {
            if store.hasMore {
                await store.loadMore()
            }
        }
        // Also trigger when swiping within 20 photos of the end. hasMore は通常 false
        // （ページングなし）なので、その場合は firstIndex の走査も走らない。
        .onChange(of: currentID) { _, newID in
            guard store.hasMore,
                  let index = store.items.firstIndex(where: { $0.id == newID }) else { return }
            if index >= store.items.count - 20 {
                Task { await store.loadMore() }
            }
        }
    }
}

// MARK: - Full-resolution photo

/// 1 ページ分のビュー。縦スクロールで写真が上にスライドし、下部に情報パネル（EXIF＋地図）が現れる。
/// 横ページング（TabView）と縦スクロールは軸が直交するため競合しない。
private struct FullPhotoView<Store: PhotoStore>: View {
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

// MARK: - Info panel

/// 写真の詳細情報パネル（日付・場所・ファイル名・カメラ・撮影情報・地図・AI抽出情報）。
private struct PhotoInfoPanel: View {
    let captureDate: Date?
    let placeName: String?
    let coordinate: CLLocationCoordinate2D?
    let exif: PhotoExifInfo?
    let insight: PhotoInsight?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let captureDate {
                header(systemImage: "calendar",
                       title: DisplayDate.ymd(captureDate),
                       subtitle: captureDate.formatted(date: .omitted, time: .shortened))
            }
            if let placeName {
                header(systemImage: "mappin.and.ellipse",
                       title: placeName,
                       subtitle: coordinateText)
            }

            insightSection

            VStack(alignment: .leading, spacing: 8) {
                detail("File", exif?.fileName)
                detail("Camera", cameraText)
                detail("Lens", exif?.lensModel)
                detail("Exposure", exposureText)
                detail("Dimensions", dimensionsText)
            }

            if let coordinate {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: coordinate, latitudinalMeters: 1_500, longitudinalMeters: 1_500
                ))) {
                    Marker("", coordinate: coordinate)
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .allowsHitTesting(false)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: Insight (AI/Vision 抽出情報)

    @ViewBuilder
    private var insightSection: some View {
        if let insight {
            VStack(alignment: .leading, spacing: 12) {
                // 状態は常に表示（未処理／解析中／完了が分かるように）。
                statusRow(insight.status, hasSignals: insight.hasSignals)

                if !insight.people.isEmpty {
                    header(systemImage: "person.2",
                           title: insight.people.joined(separator: ", "),
                           subtitle: "People")
                }
                if !insight.tags.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Detected", systemImage: "tag")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(insight.tags.joined(separator: " · "))
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statusRow(_ status: PhotoInsight.Status, hasSignals: Bool) -> some View {
        switch status {
        case .notIndexed:
            Label("AI analysis: not indexed yet", systemImage: "hourglass")
                .font(.caption).foregroundStyle(.secondary)
        case .analyzing:
            Label("AI analysis: in progress…", systemImage: "hourglass.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .ready where !hasSignals:
            Label("AI analysis: done", systemImage: "sparkles")
                .font(.caption).foregroundStyle(.secondary)
        case .ready:
            Label("AI analysis", systemImage: "sparkles")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Rows

    private func header(systemImage: String, title: String, subtitle: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                Text(value).font(.caption).textSelection(.enabled)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Formatting

    private var coordinateText: String? {
        guard let coordinate else { return nil }
        return String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private var cameraText: String? {
        guard let model = exif?.cameraModel, !model.isEmpty else { return exif?.cameraMake }
        if let make = exif?.cameraMake, !make.isEmpty, !model.localizedCaseInsensitiveContains(make) {
            return "\(make) \(model)"
        }
        return model
    }

    private var dimensionsText: String? {
        guard let w = exif?.pixelWidth, let h = exif?.pixelHeight else { return nil }
        return "\(w) × \(h)"
    }

    private var exposureText: String? {
        guard let exif else { return nil }
        var parts: [String] = []
        if let f = exif.fNumber { parts.append("ƒ\(trimmed(f))") }
        if let t = exif.exposureTime {
            parts.append(t < 1 ? "1/\(Int((1 / t).rounded()))s" : "\(trimmed(t))s")
        }
        if let iso = exif.isoSpeed { parts.append("ISO \(iso)") }
        if let focal = exif.focalLength { parts.append("\(Int(focal.rounded()))mm") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
#endif
