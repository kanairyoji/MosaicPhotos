#if canImport(UIKit)
import CoreLocation
import MapKit
import SwiftUI

/// Generic full-screen paging view. Swipe horizontally to navigate between items.
/// Toolbar shows `displayTitle` when available, otherwise formats `captureDate`.
public struct PhotoPageView<Store: PhotoStore>: View {
    let store: Store
    @State private var currentIndex: Int

    public init(store: Store, currentIndex: Int) {
        self.store = store
        self._currentIndex = State(initialValue: currentIndex)
    }

    public var body: some View {
        TabView(selection: $currentIndex) {
            ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                FullPhotoView(store: store, item: item)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color.black)
        .ignoresSafeArea()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if currentIndex < store.items.count {
                    let item = store.items[currentIndex]
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
        // Also trigger when swiping within 20 photos of the end to handle
        // cases where multiple pages have already been prefetched.
        .onChange(of: currentIndex) { _, newIndex in
            if store.hasMore && newIndex >= store.items.count - 20 {
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
    @State private var exif: PhotoExifInfo?
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var placeName: String?
    @State private var insight: PhotoInsight?
    @Environment(\.photoInsight) private var photoInsight

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
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
                }
            }
            .scrollIndicators(.hidden)
            .background(Color.black)
        }
        .task(id: item.id) {
            image = nil
            failed = false
            exif = nil
            coordinate = nil
            placeName = nil
            insight = nil
            // まずフル画像（取得時にディスクキャッシュされる）。
            if let loaded = await store.fullImage(for: item) {
                image = loaded
            } else {
                failed = true
            }
            // 続いて情報を解決：EXIF（Dropbox はキャッシュ済みファイルから抽出）→ 位置 → 地名。
            exif = await store.metadata(for: item)
            let resolved = await store.location(for: item)
            coordinate = resolved
            if let resolved {
                placeName = await PlaceNameResolver.shared.placeName(for: resolved)
            }
            // 付加情報（状態・表示タグ・人物）。アプリが注入していれば取得。
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
            Text("Unable to display.")
                .foregroundStyle(.secondary)
                .colorScheme(.dark)
        } else {
            ProgressView()
                .tint(.white)
        }
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
