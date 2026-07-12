#if canImport(UIKit)
import CoreLocation
import MosaicSupport
import SwiftUI

/// `PhotoPageView` の 1 ページ分。縦スクロールで写真が上にスライドし、下部に情報パネル（EXIF＋地図）が現れる。
/// 横ページング（TabView）と縦スクロールは軸が直交するため競合しない。
struct FullPhotoView<Store: PhotoStore>: View {
    let store: Store
    let item: Store.Item
    @State private var image: UIImage?
    /// D: フル画像が来るまでの間に見せる手元サムネ（黒画面待ちを減らす）。
    @State private var thumb: UIImage?
    @State private var failed = false
    /// 「再試行」用。インクリメントすると画像ロード `.task` が再実行される。
    @State private var retryToken = 0
    @State private var exif: PhotoExifInfo?
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var placeName: String?
    @State private var insight: PhotoInsight?
    /// 情報パネルが可視になったか（F）。下までスクロールして初めて EXIF/位置/地名/insight を解決する。
    @State private var infoRequested = false
    /// N1: 最上部で下に引っ張った量（pt）。閾値超えで閉じる。
    @State private var pullDown: CGFloat = 0
    @State private var isDismissing = false
    @Environment(\.photoInsight) private var photoInsight
    @Environment(\.dismiss) private var dismiss

    /// 下スワイプで閉じる閾値（最上部から下方向の overscroll 量・pt）。
    private static var dismissPull: CGFloat { 60 }

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                // LazyVStack：情報パネルは画面下（オフスクリーン）にあり、スクロールで可視化されるまで
                // 構築・onAppear が走らない。ページ送りを画像ロードだけに絞って軽くする（F/E）。
                LazyVStack(spacing: 0) {
                    photo
                        .frame(width: geo.size.width, height: geo.size.height)
                        // N1: 引っ張りに応じて軽く縮小＋退色させ「閉じる」フィードバックを出す。
                        // 型は明示（CGFloat/Double を混ぜると割り算演算子が多義になりビルドが落ちる）。
                        .scaleEffect(1 - min(pullDown, CGFloat(240)) / CGFloat(2400), anchor: .center)
                        .opacity(1 - Double(min(pullDown, 240)) / 600)
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
            // N1: 最上部で下に引っ張ったら閉じる。iOS 18+ の onScrollGeometryChange で実 contentOffset を見る
            //（情報パネルへの上スクロール＝contentOffset 正 では発火しない）。
            .modifier(PullDownToDismiss(pullDown: $pullDown, threshold: Self.dismissPull) {
                guard !isDismissing else { return }
                isDismissing = true
                dismiss()
            })
        }
        // フル画像のみ即ロード（取得時にディスクキャッシュ）。ページ送りはこれだけで軽い。
        // T1: 取得 nil（一時的なネットワーク断 -1005 等）は数回リトライし、
        // 全滅したときだけ failed を立てる。読み込み中は "Loading…" を見せる。
        .task(id: ImageKey(id: "\(item.id)", retry: retryToken)) {
            failed = false
            // センサー: ページ表示要求→サムネ即表示（体感）→フル画像確定の遅延。
            let t0 = PerfTrace.nowNs()
            // D: まず手元のサムネを即表示し、フル画像が来たら差し替える（開いた直後の黒画面を減らす）。
            thumb = nil
            if image == nil, let quick = await store.thumbnail(for: item), !Task.isCancelled {
                thumb = quick
                PerfTrace.count("full.quickMs", value: PerfTrace.msSince(t0))
            }
            for attempt in 0..<3 {
                if let loaded = await store.fullImage(for: item) {
                    image = loaded
                    PerfTrace.count("full.finalMs", value: PerfTrace.msSince(t0))
                    return
                }
                if Task.isCancelled { return }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(500)) }
            }
            if !Task.isCancelled { failed = true }
        }
        // 情報パネルが可視になってから解決する（F）。AI 解析（insight）と メタ/位置解決は
        // **独立に並行**して走らせる：位置解決（クラウドは通信・逆ジオコーディング）が遅い/失敗しても
        // AI 解析欄が空のまま（insight=nil でパネルが丸ごと非表示）にならないようにする。
        .task(id: infoRequested) {
            guard infoRequested else { return }
            async let insightLoad: Void = {
                if let photoInsight { insight = await photoInsight("\(item.id)") }
            }()
            async let metaLoad: Void = {
                exif = await store.metadata(for: item)
                let resolved = await store.location(for: item)
                coordinate = resolved
                if let resolved {
                    placeName = await PlaceNameResolver.shared.placeName(for: resolved)
                }
            }()
            _ = await (insightLoad, metaLoad)
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
                Text(L("Couldn’t load. Tap to retry."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .colorScheme(.dark)
            .contentShape(Rectangle())
            .onTapGesture { retryToken += 1 }
        } else {
            // D: フル画像ロード中。サムネがあれば薄く拡大して見せ、上にスピナーを重ねる
            //    （黒画面より体感が軽い）。無ければ従来どおり黒＋スピナー。
            ZStack {
                if let thumb {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFit()
                        .blur(radius: 6)
                        .opacity(0.55)
                }
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text(L("Loading…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .colorScheme(.dark)
        }
    }

    private struct ImageKey: Equatable {
        let id: String
        let retry: Int
    }
}

/// N1: フル画面の「下スワイプで閉じる」。`ScrollView` の実 contentOffset を監視し、最上部から
/// 下に引っ張った量（= -contentOffset.y）が閾値を超えたら閉じる。`pullDown` は引っ張り量を
/// 呼び出し側へ返し（縮小/退色のフィードバック用）、上スクロール（情報パネル）では 0。
private struct PullDownToDismiss: ViewModifier {
    @Binding var pullDown: CGFloat
    let threshold: CGFloat
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { _, y in
                let pull = max(0, -y)
                if pull != pullDown { pullDown = pull }
                if pull > threshold { onDismiss() }
            }
        } else {
            content   // iOS 17: 下スワイプ閉じは無効（戻るボタンで閉じる）。
        }
    }
}
#endif
