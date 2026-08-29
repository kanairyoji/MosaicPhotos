#if canImport(UIKit)
import Foundation
import LocalPhotoKit   // PhotoLibraryChangeObserver（LocalPhotoCore を再エクスポート）
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
public final class LocalAssetIndex {

    public init() {}

    private var byID: [String: PHAsset]?
    private var buildTask: Task<Void, Never>?

    /// ⚠️ 索引は**ライブラリ変更で古くなる**。無効化しないと、削除済み写真の ID を要求されたときに
    /// 古い `PHAsset` を返し続け、メンバー画面に空セルが残る（通常の fetch なら除外される）。
    /// 追いフェッチした新規アセットを索引へ入れないと毎回フェッチし直すことにもなる（レビュー指摘）。
    private var libraryObserver: PhotoLibraryChangeObserver?
    /// 索引作り直しの世代（追い越された結果を捨てる・`GenerationGuard`）。
    private var buildGeneration = GenerationGuard()
    /// 変更後は「削除済みかもしれない」と見なし、要求時に現存を確かめる（全再構築は次の機会に）。
    private var needsRevalidation = false

    /// 全ライブラリの索引を（未構築なら）バックグラウンドで構築する。utility 優先度＝
    /// 画面遷移・スクロールと CPU を奪い合わない。
    public func buildIfNeeded() {
        observeLibraryChanges()
        guard byID == nil, buildTask == nil else { return }
        rebuild()
    }

    /// 索引を作り直す。**世代**で追い越しを判定し、古い結果で新しい索引を壊さない。
    private func rebuild() {
        let generation = buildGeneration.next()
        buildTask?.cancel()
        buildTask = Task { [weak self] in
            let t0 = CFAbsoluteTimeGetCurrent()
            // 18k 件の PHAsset 列挙も起動時の山に積み上がる（`HeavyLoad`・diagnostics-66）。
            HeavyLoad.begin("assetIndex")
            defer { HeavyLoad.end("assetIndex") }
            let built = await Task.detached(priority: .utility) { () -> [String: PHAsset] in
                let result = PHAsset.fetchAssets(with: .image, options: nil)
                var dict: [String: PHAsset] = [:]
                dict.reserveCapacity(result.count)
                result.enumerateObjects { asset, _, _ in dict[asset.localIdentifier] = asset }
                return dict
            }.value
            guard let self, self.buildGeneration.isCurrent(generation) else { return }
            self.byID = built
            self.buildTask = nil
            self.needsRevalidation = false   // 作り直した＝現存だけが入っている
            Diagnostics.mark("assetIndex: built \(built.count) in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")
        }
    }

    /// ライブラリ変更を監視して索引を無効化する（多重登録しない）。
    private func observeLibraryChanges() {
        guard libraryObserver == nil else { return }
        let observer = PhotoLibraryChangeObserver { [weak self] in
            Task { @MainActor in self?.invalidate() }
        }
        PHPhotoLibrary.shared().register(observer)
        libraryObserver = observer
    }

    /// 変更を受けたら「古いかもしれない」と印を付け、裏で作り直す。
    ///
    /// ⚠️ ここで `byID` を捨てない。捨てると作り直しが終わるまで索引が無い状態になり、
    /// アルバムを開くたびに従来の全フェッチへ落ちる（体感が戻る）。印がある間は
    /// 要求のたびに現存を確かめるので、削除済みを返すことはない。
    private func invalidate() {
        needsRevalidation = true
        Diagnostics.mark("assetIndex: invalidated by library change")
        rebuild()
    }

    /// 単一 ID の PHAsset（索引にあれば辞書引き・無ければ単発フェッチ）。
    /// 変更直後は索引を信用せず、現存を確かめてから返す。
    public func asset(for id: String) -> PHAsset? {
        buildIfNeeded()
        if !needsRevalidation, let asset = byID?[id] { return asset }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        if let fetched { byID?[id] = fetched } else { byID?.removeValue(forKey: id) }
        return fetched
    }

    /// メンバー ID 群に対応する PHAsset。索引未構築なら nil
    /// （呼び出し側は従来の `LocalPhotoStore(localIdentifiers:)` へフォールバック）。
    /// 2-d: **ソートはしない**（撮影日昇順への整列は `LocalPhotoStore(preloadedAssets:)` が
    /// off-main で行う）。ここは辞書引き＋不足分の追いフェッチだけ＝メインでの sort を避ける。
    public func assets(for ids: [String]) -> [PHAsset]? {
        buildIfNeeded()
        guard let index = byID else { return nil }
        // ⚠️ ライブラリ変更の直後は索引を信用しない。**現存する写真だけ**を返す
        // （削除済みを返すとメンバー画面に空セルが残る）。
        if needsRevalidation {
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var live: [PHAsset] = []
            live.reserveCapacity(fetched.count)
            fetched.enumerateObjects { asset, _, _ in live.append(asset) }
            for asset in live { byID?[asset.localIdentifier] = asset }
            let removed = ids.count - live.count
            if removed > 0 { Diagnostics.mark("assetIndex: dropped \(removed) deleted photo(s)") }
            return live
        }
        var found: [PHAsset] = []
        found.reserveCapacity(ids.count)
        var missing: [String] = []
        for id in ids {
            if let asset = index[id] { found.append(asset) } else { missing.append(id) }
        }
        // 索引構築後に追加された写真だけ小さく追いフェッチ（通常ゼロ〜数枚・ms 級）。
        // ⚠️ 取れた分は**索引へ入れる**（入れないと開くたびに同じフェッチを繰り返す）。
        if !missing.isEmpty {
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil)
            fetched.enumerateObjects { asset, _, _ in
                found.append(asset)
                self.byID?[asset.localIdentifier] = asset
            }
            Diagnostics.mark("assetIndex: top-up fetch \(missing.count) missing → \(fetched.count)")
        }
        return found
    }
}
#endif
