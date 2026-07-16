import Foundation
import MosaicSupport
import Photos

/// PHAsset の全ライブラリ索引（localIdentifier → PHAsset）。
///
/// アルバム系ビュー（AI アルバム・ピープル・場所・端末アルバム）はメンバーの
/// `fetchAssets(withLocalIdentifiers:)` で開くたびにライブラリ走査（数千メンバーで
/// 数百 ms 級）が走っていた。起動後の段階起動で**一度だけ**全列挙して辞書化し、
/// 以後のアルバムオープンを O(メンバー数) の辞書引きにする（体感高速化）。
///
/// - 索引構築前に開いた場合は nil を返し、呼び出し側は従来のフェッチへフォールバック。
/// - 索引構築**後**に撮影/取り込みされた写真は辞書に無いため、不足分だけ小さく
///   追いフェッチして取りこぼさない（正確性を犠牲にしない）。
@MainActor
final class LocalAssetIndex {
    private var byID: [String: PHAsset]?
    private var buildTask: Task<Void, Never>?

    /// 全ライブラリの索引を（未構築なら）バックグラウンドで構築する。utility 優先度＝
    /// 画面遷移・スクロールと CPU を奪い合わない。
    func buildIfNeeded() {
        guard byID == nil, buildTask == nil else { return }
        buildTask = Task { [weak self] in
            let t0 = CFAbsoluteTimeGetCurrent()
            let built = await Task.detached(priority: .utility) { () -> [String: PHAsset] in
                let result = PHAsset.fetchAssets(with: .image, options: nil)
                var dict: [String: PHAsset] = [:]
                dict.reserveCapacity(result.count)
                result.enumerateObjects { asset, _, _ in dict[asset.localIdentifier] = asset }
                return dict
            }.value
            self?.byID = built
            self?.buildTask = nil
            Diagnostics.mark("assetIndex: built \(built.count) in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")
        }
    }

    /// メンバー ID 群に対応する PHAsset（撮影日昇順）。索引未構築なら nil
    /// （呼び出し側は従来の `LocalPhotoStore(localIdentifiers:)` へフォールバック）。
    func assets(for ids: [String]) -> [PHAsset]? {
        buildIfNeeded()
        guard let byID else { return nil }
        var found: [PHAsset] = []
        found.reserveCapacity(ids.count)
        var missing: [String] = []
        for id in ids {
            if let asset = byID[id] { found.append(asset) } else { missing.append(id) }
        }
        // 索引構築後に追加された写真だけ小さく追いフェッチ（通常ゼロ〜数枚・ms 級）。
        if !missing.isEmpty {
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil)
            fetched.enumerateObjects { asset, _, _ in found.append(asset) }
            Diagnostics.mark("assetIndex: top-up fetch \(missing.count) missing → \(fetched.count)")
        }
        return found.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
    }
}
