import AutoAlbumCore
import Photos
import SwiftUI
import UIKit

/// AI キャプション（VLM＝Florence）が付いた写真を、生成された説明文とサムネイルで一覧確認する画面。
/// 「AI による説明」の解析が本当に効いているかを、ユーザー/開発者が目視で確かめるために使う。
/// 設定「AI 解析の状況」→「説明を確認」から開く。
struct CaptionedPhotosView: View {
    let engine: AutoAlbumEngine

    @State private var samples: [CaptionSample] = []
    @State private var loaded = false

    struct CaptionSample: Identifiable {
        let refKey: String
        let caption: String
        var id: String { refKey }
    }

    var body: some View {
        List {
            if loaded && samples.isEmpty {
                ContentUnavailableView(L("No descriptions yet"),
                                       systemImage: "text.below.photo",
                                       description: Text(L("Descriptions are generated on device while charging. Check back later.")))
            } else {
                Section {
                    ForEach(samples) { sample in
                        row(sample)
                    }
                } footer: {
                    if !samples.isEmpty {
                        Text(L("Showing \(samples.count) photos with an AI description."))
                    }
                }
            }
        }
        .navigationTitle(L("AI Descriptions"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            samples = (await engine.captionedSamples(limit: 300))
                .map { CaptionSample(refKey: $0.refKey, caption: $0.caption) }
            loaded = true
        }
    }

    private func row(_ sample: CaptionSample) -> some View {
        HStack(alignment: .top, spacing: 12) {
            CaptionThumbnail(refKey: sample.refKey)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(sample.caption)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(sourceLabel(sample.refKey))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func sourceLabel(_ refKey: String) -> String {
        switch PhotoRef.decode(refKey) {
        case .local:  return L("On-device")
        case .cloud:  return L("Cloud")
        case nil:     return refKey
        }
    }
}

/// refKey のサムネイル。ローカル（PHAsset）は PhotosKit で直接取得。クラウドはプレースホルダ。
private struct CaptionThumbnail: View {
    let refKey: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: PhotoRef.decode(refKey)?.cloudPath != nil ? "cloud" : "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: refKey) { await load() }
    }

    private func load() async {
        guard case .local(let localID)? = PhotoRef.decode(refKey) else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil)
        guard let asset = assets.firstObject else { return }
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .highQualityFormat   // 1 回だけコールバック（continuation の多重 resume を避ける）
        opts.resizeMode = .fast
        let target = CGSize(width: 128, height: 128)
        let img: UIImage? = await withCheckedContinuation { cont in
            PHImageManager.default().requestImage(for: asset, targetSize: target,
                                                  contentMode: .aspectFill, options: opts) { result, _ in
                cont.resume(returning: result)
            }
        }
        if let img { image = img }
    }
}
