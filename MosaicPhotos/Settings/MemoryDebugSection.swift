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

    var body: some View {
        deviceSection
        cacheSection
        processingSection
    }

    // MARK: - 端末 & 実行時

    private var deviceSection: some View {
        let power = PowerStateMonitor.shared
        let net = NetworkStateMonitor.shared
        return Section {
            LabeledContent("Device RAM", value: formattedBytes(Int(ProcessInfo.processInfo.physicalMemory)))
            LabeledContent("Memory footprint",
                           value: currentMemoryFootprintMB().map { String(format: "%.0f MB", $0) } ?? "—")
            LabeledContent("Memory pressure", value: bool(MemoryPressureMonitor.shared.isUnderPressure))
            LabeledContent("Low Power Mode", value: bool(power.isLowPowerMode))
            LabeledContent("On power", value: bool(power.isOnPower))
            LabeledContent("Power policy", value: powerPolicyName(power.policy))
            LabeledContent("Background allowed", value: bool(power.backgroundAllowed()))
            LabeledContent("Network", value: networkState(net))
            LabeledContent("Data policy", value: dataPolicyName(net.policy))
            LabeledContent("Background data allowed", value: bool(net.networkAllowed()))
        } header: {
            Text("Memory — Device & Runtime")
        } footer: {
            Text("Live values the app currently reads. “Background allowed” = power policy is satisfied; "
                 + "“Background data allowed” = network policy is satisfied.")
        }
    }

    // MARK: - キャッシュ上限

    private var cacheSection: some View {
        Section {
            LabeledContent("Local thumb memory", value: localMemoryLimitText)
            LabeledContent("Local thumb disk limit", value: "\(diskLimitMB) MB")
            LabeledContent("Local thumb disk usage", value: formattedBytes(localDiskUsage))
            LabeledContent("Dropbox thumb memory",
                           value: "\(DropboxDebugConstants.thumbnailMemoryCostLimitMB) MB / "
                                + "\(DropboxDebugConstants.thumbnailMemoryCountLimit) items")
            LabeledContent("Dropbox disk (thumb/full) default",
                           value: "\(DropboxDebugConstants.defaultThumbnailLimitMB) / "
                                + "\(DropboxDebugConstants.defaultFullImageLimitMB) MB")
            LabeledContent("Full image max pixel", value: "\(ImageCacheTuning.fullImageMaxPixel) px")
            LabeledContent("Pressure shrink",
                           value: "floor \(ImageCacheTuning.memoryPressureFloorMB) MB / "
                                + "restore \(ImageCacheTuning.memoryPressureRestoreSeconds)s")
        } header: {
            Text("Memory — Caches")
        } footer: {
            Text("Thumbnail memory caches use real decoded-size cost. “Auto” scales the local limit to "
                 + "device RAM (~1.5%, 40–120 MB). Under memory pressure the limit is temporarily halved.")
        }
        .task { localDiskUsage = await ThumbnailCache.shared.currentDiskUsage() }
    }

    // MARK: - バックグラウンド処理

    private var processingSection: some View {
        let bg = BackgroundActivityMonitor.shared
        let preset = BackgroundProcessing.preset(at: backgroundLevel)
        return Section {
            LabeledContent("Embedding preset",
                           value: "\(preset.name) — \(preset.batchSize)/batch · \(format1(preset.pauseSeconds))s")
            LabeledContent("Embedding running", value: bool(bg.isEmbedding))
            LabeledContent("Embedding remaining", value: "\(bg.embedRemaining)")
            LabeledContent("Embedding storage", value: "Float16 ≈ 1 KB/photo (PhotoEmbedding)")
            LabeledContent("Search page size", value: "\(AutoAlbumTuning.semanticSearchPageSize)")
            LabeledContent("Upsert write chunk", value: "\(AutoAlbumTuning.upsertWriteChunk)")
        } header: {
            Text("Memory — Background Processing")
        }
    }

    // MARK: - Helpers

    private var localMemoryLimitText: String {
        if memoryLimitMB > 0 { return "\(memoryLimitMB) MB" }
        let mb = ThumbnailMemoryBudget.effectiveBytes(forSettingMB: 0) / (1024 * 1024)
        return "Auto (\(mb) MB)"
    }

    private func bool(_ v: Bool) -> String { v ? "Yes" : "No" }
    private func format1(_ v: Double) -> String { String(format: "%.1f", v) }

    private func networkState(_ n: NetworkStateMonitor) -> String {
        guard n.isReachable else { return "Offline" }
        var s = n.isOnWiFi ? "Wi-Fi" : "Cellular"
        if n.isConstrained { s += " · Low Data" }
        if n.isExpensive { s += " · Expensive" }
        return s
    }

    private func powerPolicyName(_ p: BackgroundPowerPolicy) -> String {
        switch p {
        case .whileCharging: return "While charging"
        case .always:        return "Always"
        case .off:           return "Off"
        }
    }

    private func dataPolicyName(_ p: BackgroundDataPolicy) -> String {
        switch p {
        case .wifiOnly:      return "Wi-Fi only"
        case .unrestricted:  return "Cellular allowed"
        case .wifiNoLowData: return "Wi-Fi, skip Low Data"
        case .off:           return "Off"
        }
    }
}
