import AutoAlbumCore
import DropboxKit
import LocalPhotoKit
import MosaicSupport
import SwiftUI

/// Developer Options のメモリ診断。端末 RAM・現在のフットプリント・各キャッシュ上限・
/// バックグラウンドのチューニング値・電源/回線の判定状態など、内部値をまとめて確認できる。
/// 値は実行時にアプリが参照しているものをそのまま表示する。
struct MemoryDebugSection: View {
    @AppStorage(CacheSettingsKeys.memoryLimitMB) private var memoryLimitMB = 0
    @AppStorage(CacheSettingsKeys.diskLimitMB)   private var diskLimitMB   = 500
    @AppStorage(AutoAlbumSettingsKeys.backgroundProcessingLevel)
    private var backgroundLevel = BackgroundProcessing.defaultIndex

    @State private var localDiskUsage = 0
    @State private var pressureEvents: [MemoryPressureEvent] = []
    @State private var pressureCount = 0

    var body: some View {
        deviceSection
        cacheSection
        processingSection
        pressureSection
    }

    // MARK: - 端末 & 実行時

    private var deviceSection: some View {
        let power = PowerStateMonitor.shared
        let net = NetworkStateMonitor.shared
        return Section {
            LabeledContent("端末の RAM", value: formattedBytes(Int(ProcessInfo.processInfo.physicalMemory)))
            LabeledContent("メモリ使用量",
                           value: currentMemoryFootprintMB().map { String(format: "%.0f MB", $0) } ?? "—")
            LabeledContent("メモリ圧迫中", value: bool(MemoryPressureMonitor.shared.isUnderPressure))
            LabeledContent("低電力モード", value: bool(power.isLowPowerMode))
            LabeledContent("電源接続中", value: bool(power.isOnPower))
            LabeledContent("電源ポリシー", value: powerPolicyName(power.policy))
            LabeledContent("背景処理を許可（電源）", value: bool(power.backgroundAllowed()))
            LabeledContent("アイドル秒数", value: String(format: "%.0fs", BackgroundActivityMonitor.shared.idleSeconds))
            LabeledContent("いま重い処理を実行してよいか", value: bool(BackgroundYield.heavyWorkAllowed))
            LabeledContent("回線", value: networkState(net))
            LabeledContent("通信ポリシー", value: dataPolicyName(net.policy))
            LabeledContent("背景通信を許可（回線）", value: bool(net.networkAllowed()))
        } header: {
            Text("メモリ：端末と実行状態")
        } footer: {
            Text("いまアプリが参照している値です。「背景処理を許可（電源）」＝電源ポリシーを満たしている、"
                 + "「背景通信を許可（回線）」＝通信ポリシーを満たしている、という意味です。")
        }
    }

    // MARK: - キャッシュ上限

    private var cacheSection: some View {
        Section {
            LabeledContent("ローカルのサムネ（メモリ上限）", value: localMemoryLimitText)
            LabeledContent("ローカルのサムネ（ディスク上限）", value: "\(diskLimitMB) MB")
            LabeledContent("ローカルのサムネ（ディスク使用量）", value: formattedBytes(localDiskUsage))
            LabeledContent("Dropbox のサムネ（メモリ）",
                           value: "\(DropboxDebugConstants.thumbnailMemoryCostLimitMB) MB / "
                                + "\(DropboxDebugConstants.thumbnailMemoryCountLimit) 件")
            LabeledContent("Dropbox のディスク上限（サムネ/フル）既定",
                           value: "\(DropboxDebugConstants.defaultThumbnailLimitMB) / "
                                + "\(DropboxDebugConstants.defaultFullImageLimitMB) MB")
            LabeledContent("フル画像の最大ピクセル", value: "\(ImageCacheTuning.fullImageMaxPixel) px")
            LabeledContent("圧迫時の縮小",
                           value: "下限 \(ImageCacheTuning.memoryPressureFloorMB) MB / "
                                + "復帰 \(ImageCacheTuning.memoryPressureRestoreSeconds)s")
        } header: {
            Text("メモリ：キャッシュ")
        } footer: {
            Text("サムネのメモリキャッシュは、デコード後の実サイズをコストとして数えます。「自動」は端末の "
                 + "RAM に応じて上限を調整します（約 1.5%・40〜120 MB）。メモリ圧迫時は上限を一時的に半減します。")
        }
        .task { localDiskUsage = await ThumbnailCache.shared.currentDiskUsage() }
    }

    // MARK: - バックグラウンド処理

    private var processingSection: some View {
        let bg = BackgroundActivityMonitor.shared
        let preset = BackgroundProcessing.preset(at: backgroundLevel)
        return Section {
            LabeledContent("埋め込みの速度プリセット",
                           value: "\(preset.name) — \(preset.batchSize)/バッチ · \(format1(preset.pauseSeconds))s")
            LabeledContent("埋め込み実行中", value: bool(bg.isEmbedding))
            LabeledContent("埋め込み残り", value: "\(bg.embedRemaining)")
            LabeledContent("埋め込みの保存形式", value: "Float16 ≈ 1 KB/枚（PhotoEmbedding）")
            LabeledContent("検索のページサイズ", value: "\(AutoAlbumTuning.semanticSearchPageSize)")
            LabeledContent("書き込みチャンク（upsert）", value: "\(AutoAlbumTuning.upsertWriteChunk)")
        } header: {
            Text("メモリ：背景処理")
        } footer: {
            Text("夜間に CLIP 埋め込みを付与する背景処理の状態と、内部のチューニング値です。"
                 + "速度プリセットは設定「アルバム」で変更できます。")
        }
    }

    // MARK: - 圧迫イベント履歴

    private var pressureSection: some View {
        Section {
            LabeledContent("圧迫イベント（累計）", value: "\(pressureCount)")
            if pressureEvents.isEmpty {
                Text("メモリ圧迫イベントは記録されていません。").foregroundStyle(.secondary)
            } else {
                ForEach(Array(pressureEvents.prefix(8).enumerated()), id: \.offset) { _, e in
                    LabeledContent(
                        e.date.formatted(date: .omitted, time: .standard),
                        value: e.level.rawValue + " · "
                            + (e.footprintMB.map { String(format: "%.0f MB", $0) } ?? "—"))
                }
            }
        } header: {
            Text("メモリ：圧迫の履歴")
        } footer: {
            Text("warning（警告）では画像キャッシュを縮小（上限を半減）、critical（危機）では全消去します。"
                 + "各イベントは端末 RAM と使用量とともに診断ログにも記録されます。")
        }
        .task {
            pressureCount = MemoryPressureMonitor.shared.totalPressureCount
            pressureEvents = MemoryPressureMonitor.shared.recentEvents()
        }
    }

    // MARK: - Helpers

    private var localMemoryLimitText: String {
        if memoryLimitMB > 0 { return "\(memoryLimitMB) MB" }
        let mb = ThumbnailMemoryBudget.effectiveBytes(forSettingMB: 0) / (1024 * 1024)
        return "自動（\(mb) MB）"
    }

    private func bool(_ v: Bool) -> String { v ? "はい" : "いいえ" }
    private func format1(_ v: Double) -> String { String(format: "%.1f", v) }

    private func networkState(_ n: NetworkStateMonitor) -> String {
        guard n.isReachable else { return "オフライン" }
        var s = n.isOnWiFi ? "Wi-Fi" : "モバイル回線"
        if n.isConstrained { s += " · 低データ" }
        if n.isExpensive { s += " · 従量課金" }
        return s
    }

    private func powerPolicyName(_ p: BackgroundPowerPolicy) -> String {
        switch p {
        case .whileCharging: return "充電中のみ"
        case .always:        return "常に"
        case .off:           return "オフ"
        }
    }

    private func dataPolicyName(_ p: BackgroundDataPolicy) -> String {
        switch p {
        case .wifiOnly:      return "Wi-Fi のみ"
        case .unrestricted:  return "モバイル回線も許可"
        case .wifiNoLowData: return "Wi-Fi（低データは除く）"
        case .off:           return "オフ"
        }
    }
}
