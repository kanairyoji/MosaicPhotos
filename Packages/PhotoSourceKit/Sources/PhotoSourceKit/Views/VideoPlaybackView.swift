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
///
/// ネット越しに流す動画（Dropbox・ADR-282）は、**先読みと同じ規則**
/// （`NetworkStateMonitor.speculativeFetchAllowed`＝設定の通信ポリシー × 低電力モード）が
/// 許すときだけ自動で流す。許さないとき（既定ではモバイル通信）は大きさを見せてタップを待つ。
/// 再生できるかは拡張子で決め打ちせず、開いてから確かめる（`isPlayable`）。
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
    /// モバイル通信なのでタップを待っている。
    @State private var awaitingTap = false
    /// 利用者が「再生」を押した（以後このページでは待たない）。
    @State private var playRequested = false
    /// iOS が再生できない形式だった。
    @State private var unplayable = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .padding(insets)
            } else if unplayable {
                posterLayer
                VStack(spacing: 12) {
                    Image(systemName: "film")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(L("This video format can’t be played in this app."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let viewer = store.externalViewer(for: item) {
                        Button(viewer.title) { openURL(viewer.url) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(24)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                .colorScheme(.dark)
            } else if awaitingTap {
                posterLayer
                Button {
                    playRequested = true
                    retryToken += 1
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 64))
                            .symbolRenderingMode(.hierarchical)
                        if let size = streamingSizeText {
                            Text(size).font(.footnote.monospacedDigit())
                        }
                    }
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Play"))
                .colorScheme(.dark)
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
                    posterLayer
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
            // ネット越しの動画は、自動で流してよい回線か確かめる（モバイル通信ではタップを待つ）。
            if !playRequested, store.streamingInfo(for: item) != nil,
               !NetworkStateMonitor.shared.speculativeFetchAllowed() {
                awaitingTap = true
                Diagnostics.mark("video: waiting for tap (metered network)")
                return
            }
            awaitingTap = false
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
            // 再生できる形式か（拡張子では決めない＝OS の対応に任せる）。
            // ⚠️ 確かめられなかった（通信の失敗など）ときは再生を試す側に倒す
            // ——プレーヤーが自分で失敗を出すほうが、「再生できない形式」と誤って言うよりよい。
            let playable = (try? await playerItem.asset.load(.isPlayable)) ?? true
            guard !Task.isCancelled else { return }
            if !playable {
                unplayable = true
                Diagnostics.mark("video: format not playable")
                return
            }
            let newPlayer = AVPlayer(playerItem: playerItem)
            player = newPlayer
            newPlayer.play()
        }
        .onDisappear { stop() }
    }

    private var posterLayer: some View {
        Group {
            if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFit()
                    .padding(insets)
            }
        }
    }

    /// 流す前に見せる大きさ（例「48.2 MB」）。分からなければ nil。
    private var streamingSizeText: String? {
        guard let bytes = store.streamingInfo(for: item)?.byteSize, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
