#if canImport(UIKit)
import DropboxCore
import SwiftUI

/// Dropbox 通信アクティビティの表示トグル用キー（Developer Options から ON/OFF）。
public enum DropboxActivitySettingsKeys {
    public static let showBar = "debug.dropboxActivityBar"
}

/// 画面最上部に出す Dropbox 通信アクティビティの「スロット LED」インジケータ。
///
/// 形＝チャンネル / 色＝状態 / 数・塗り＝強度 の方針:
/// - サムネイル: 同時実行スロットをレーン（ピップ）で表示。稼働=青／空き=灰、末尾に先読み待ち枚数。
/// - 同期: 1 ランプ（差分取得=青点滅 / 監視=緑 / 初回=青 / 失敗=赤 / 待機=灰）。
/// - フル画像DL: ⬇＋本数。 バックアップ: ⬆ランプ。
///
/// `DropboxActivityMonitor`（@Observable）を購読してライブ更新する。Dropbox 設定の
/// 「Show activity bar」トグル（既定 ON）が ON のときだけ `dropboxActivityBar()` 経由で表示される。
public struct DropboxActivityBar: View {
    public init() {}

    public var body: some View {
        let m = DropboxActivityMonitor.shared
        HStack(spacing: 10) {
            // チャンネル識別ラベル。
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)

            // サムネイル並列スロット（レーン LED）。
            HStack(spacing: 3) {
                ForEach(0..<max(m.thumbnailSlotCapacity, 1), id: \.self) { i in
                    Capsule(style: .continuous)
                        .fill(i < m.thumbnailActiveSlots ? Color.blue : Color.secondary.opacity(0.25))
                        .frame(width: 5, height: 11)
                }
                if m.thumbnailPending > 0 {
                    Text("⟳\(m.thumbnailPending)")
                        .font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            divider

            // 同期ランプ。
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(syncColor(m.sync))
                    .symbolEffect(.pulse, options: .repeating, isActive: syncBusy(m.sync))
            }

            // フル画像ダウンロード。
            channelLamp(systemName: "arrow.down.circle.fill",
                        active: m.fullImageActive > 0,
                        count: m.fullImageActive,
                        color: .teal)

            // バックアップアップロード。
            channelLamp(systemName: "arrow.up.circle.fill",
                        active: m.backupActive,
                        count: 0,
                        color: .orange)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .allowsHitTesting(false)   // 表示専用。タップは下のビューへ素通し。
    }

    private var divider: some View {
        Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1, height: 12)
    }

    @ViewBuilder
    private func channelLamp(systemName: String, active: Bool, count: Int, color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? color : Color.secondary.opacity(0.3))
            if active, count > 1 {
                Text("\(count)")
                    .font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func syncColor(_ s: DropboxActivityMonitor.SyncActivity) -> Color {
        switch s {
        case .idle:         return Color.secondary.opacity(0.3)
        case .initialSync:  return .blue
        case .fetchingDelta: return .blue
        case .polling:      return .green
        case .error:        return .red
        }
    }

    private func syncBusy(_ s: DropboxActivityMonitor.SyncActivity) -> Bool {
        switch s {
        case .initialSync, .fetchingDelta: return true
        default: return false
        }
    }
}

// MARK: - Modifier

private struct DropboxActivityBarModifier: ViewModifier {
    @AppStorage(DropboxActivitySettingsKeys.showBar) private var enabled = true

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if enabled {
                DropboxActivityBar()
                    .padding(.top, 2)
                    .transition(.opacity)
            }
        }
    }
}

public extension View {
    /// 画面最上部に Dropbox 通信アクティビティのインジケータを重ねる（Developer Options で ON のとき）。
    func dropboxActivityBar() -> some View {
        modifier(DropboxActivityBarModifier())
    }
}
#endif
