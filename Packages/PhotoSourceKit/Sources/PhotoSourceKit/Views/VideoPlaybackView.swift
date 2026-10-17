#if canImport(UIKit)
import AVKit
import MosaicSupport
import SwiftUI

/// `FullPhotoView` の動画版の本体。表示中のページになったら自動で再生し（音あり）、
/// ページを送ったら止めてプレーヤーを手放す。
///
/// ⚠️ **プレーヤーは表示中のページだけが持つ**。ページャ（`TabView`）は前後のページも
/// 生かしておくので、`onAppear` で作ると隣のページの動画まで読み込んで鳴り出す。
/// `isCurrent` が偽になったら止めて捨てる（メモリも iCloud の取得も有界に保つ）。
///
/// 音は既定のオーディオセッション（`soloAmbient`）に任せる＝消音スイッチに従い、
/// 他のアプリの音楽は止まる（写真アプリと同じ）。
struct VideoPlaybackView<Store: PhotoStore>: View {
    let store: Store
    let item: Store.Item
    /// ページャで今見えているページか。
    let isCurrent: Bool
    /// プレーヤーを置く余白（上の日付ラベルと下の操作バーに AVKit の操作部が隠れないように）。
    let insets: EdgeInsets
    @State private var player: AVPlayer?
    /// 再生できるまでの間に見せる静止画（サムネ）。
    @State private var poster: UIImage?
    @State private var failed = false
    /// 「再試行」用。
    @State private var retryToken = 0

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .padding(insets)
            } else if failed {
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
                ZStack {
                    if let poster {
                        Image(uiImage: poster)
                            .resizable()
                            .scaledToFit()
                            .padding(insets)
                    }
                    if isCurrent { ProgressView().tint(.white) }
                }
                .colorScheme(.dark)
            }
        }
        .task(id: Key(isCurrent: isCurrent, retry: retryToken)) {
            guard isCurrent else {
                stop()
                if poster == nil { poster = await store.thumbnail(for: item) }
                return
            }
            failed = false
            if poster == nil { poster = await store.thumbnail(for: item) }
            // 実機で確かめること（iCloud 上の動画が再生できるまでの待ち・失敗）の答えをログに出す。
            let t0 = PerfTrace.nowNs()
            guard let playerItem = await store.playerItem(for: item) else {
                if !Task.isCancelled {
                    failed = true
                    Diagnostics.mark("video: player item unavailable after \(Int(PerfTrace.msSince(t0)))ms")
                }
                return
            }
            Diagnostics.mark("video: player item ready in \(Int(PerfTrace.msSince(t0)))ms")
            // 取得の間にページを送られていたら再生しない（タスクは取り消されている）。
            guard !Task.isCancelled else { return }
            let newPlayer = AVPlayer(playerItem: playerItem)
            player = newPlayer
            newPlayer.play()
        }
        .onDisappear { stop() }
    }

    private func stop() {
        player?.pause()
        player = nil
    }

    private struct Key: Equatable {
        let isCurrent: Bool
        let retry: Int
    }
}
#endif
