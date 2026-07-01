#if canImport(UIKit)
import DropboxCore
import MosaicSupport
import SwiftUI

/// アクティビティバーの表示トグル用キー（設定 → Dropbox から ON/OFF）。
public enum DropboxActivitySettingsKeys {
    public static let showBar = "debug.dropboxActivityBar"
}

/// 画面最上部に出す「アクティビティバー」。Dropbox 通信に加え、電源ゲートと
/// バックグラウンド処理（AI 埋め込み・自動アルバム生成・場所/アルバム走査）の稼働状況を 1 行で示す。
///
/// 形＝チャンネル / 色＝状態 / 数・塗り＝強度 の方針:
/// - 電源: ⚡稼働可(緑) / 電池待ち(橙) / Off(灰)。背景処理が動くかの大元。
/// - Dropbox: サムネ同時スロット(レーン)＋先読み待ち / 同期ランプ / フル画像DL / バックアップ。
/// - 背景処理: AI 埋め込み(残り枚数)・アルバム生成・場所走査・アルバム走査の各ランプ（稼働中はパルス）。
///
/// `DropboxActivityMonitor` / `BackgroundActivityMonitor` / `PowerStateMonitor`（いずれも @Observable）を
/// 購読してライブ更新する。設定「Show activity bar」（既定 ON）が ON のときだけ表示される。
public struct DropboxActivityBar: View {
    public init() {}

    public var body: some View {
        let m = DropboxActivityMonitor.shared
        let bg = BackgroundActivityMonitor.shared
        let power = PowerStateMonitor.shared
        let net = NetworkStateMonitor.shared
        HStack(spacing: 9) {
            // 電源ゲート＋回線ゲート（背景処理／背景通信の大元）。
            powerChip(power)
            networkChip(net)

            divider

            // ── Dropbox 通信 ──
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

            // 同期ランプ。
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(syncColor(m.sync))
                .symbolEffect(.pulse, options: .repeating, isActive: syncBusy(m.sync))

            // フル画像ダウンロード。
            channelLamp(systemName: "arrow.down.circle.fill",
                        active: m.fullImageActive > 0, count: m.fullImageActive, color: .teal)
            // バックアップアップロード。
            channelLamp(systemName: "arrow.up.circle.fill",
                        active: m.backupActive, count: 0, color: .orange)

            divider

            // ── バックグラウンド処理 ──
            // AI 埋め込み（残り枚数を併記）。
            bgLamp("sparkles", active: bg.isEmbedding, color: .purple, count: bg.embedRemaining)
            // 自動アルバム生成。
            bgLamp("rectangle.stack.fill", active: bg.isGeneratingAlbums, color: .blue)
            // 場所スキャン。
            bgLamp("mappin.and.ellipse", active: bg.isScanningPlaces, color: .green)
            // アルバム走査。
            bgLamp("photo.on.rectangle", active: bg.isScanningAlbums, color: .green)
            // ピープル（顔スキャン・残り枚数を併記）。
            bgLamp("person.2.fill", active: bg.isScanningFaces, color: .indigo, count: bg.faceScanRemaining)
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

    // 電源ゲート: 稼働可(緑⚡) / 電池待ち(橙) / ポリシー Off(灰)。
    private func powerChip(_ p: PowerStateMonitor) -> some View {
        let icon: String
        let color: Color
        if p.policy == .off {
            icon = "pause.circle.fill"; color = Color.secondary.opacity(0.5)
        } else if p.backgroundAllowed() {
            icon = "bolt.fill"; color = .green
        } else {
            icon = "bolt.slash.fill"; color = .orange
        }
        return Image(systemName: icon)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
    }

    // 回線ゲート: 背景通信OK(緑 Wi-Fi) / 回線はあるが保留(橙) / Off・圏外(灰)。
    private func networkChip(_ n: NetworkStateMonitor) -> some View {
        let icon: String
        let color: Color
        if n.policy == .off || !n.isReachable {
            icon = "wifi.slash"; color = Color.secondary.opacity(0.5)
        } else if n.networkAllowed() {
            icon = "wifi"; color = .green
        } else {
            icon = "wifi.exclamationmark"; color = .orange   // 例: セルラーで Wi-Fi 待ち
        }
        return Image(systemName: icon)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
    }

    // 背景処理ランプ（稼働中はパルス、count>0 で枚数併記）。
    @ViewBuilder
    private func bgLamp(_ systemName: String, active: Bool, color: Color, count: Int = 0) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? color : Color.secondary.opacity(0.3))
                .symbolEffect(.pulse, options: .repeating, isActive: active)
            if active, count > 0 {
                Text(compactCount(count))
                    .font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func compactCount(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
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
                    .padding(.top, 0)   // 安全領域上端にぴったり寄せる（フル画面の日付はこの下へ配置）
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
