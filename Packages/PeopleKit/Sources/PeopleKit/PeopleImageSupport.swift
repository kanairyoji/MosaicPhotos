#if canImport(UIKit)
import AutoAlbumCore
import CoreGraphics
import MosaicSupport
import Photos
import UIKit

// MARK: - クラウド写真の取得 seam
//
// ⚠️ もとはアプリの `HeavyWorkScheduler.stores`（グローバル）を直に触っていた。パッケージから
// アプリを見ることはできないので、**注入点**にする（Composition Root がアプリ起動時に設定）。
// 設定されていなければクラウド顔のアバターが出ないだけで、機能は壊れない。
@MainActor
public enum PeopleImageSources {
    /// キャッシュ済みのクラウドサムネを返す（**ダウンロードはしない**・ADR-88）。
    public static var cachedCloudThumbnail: ((String) async -> UIImage?)?
    /// 次の表示に間に合うよう温める（低優先・回線ポリシー内・ADR-81）。
    public static var warmCloudThumbnail: ((String) -> Void)?

    /// ⚠️ 未配線は**黙って「顔が出ない」**になる（実際にパッケージ分離で落として、
    /// 「まとめて確認のサムネが出ない」という形で表に出た）。気づけるよう 1 回だけ記録する。
    private static var loggedMissingSource = false
    static func noteMissingCloudSource() {
        guard !loggedMissingSource else { return }
        loggedMissingSource = true
        Diagnostics.mark("people: cloud thumbnail source not wired — クラウド写真の顔は出ません")
    }
}

// MARK: - Cluster members → local identifiers

/// クラスタのメンバー refKey をローカル localIdentifier 配列へ。
public func localIdentifiers(from refKeys: [String]) -> [String] {
    refKeys.compactMap { PhotoRef.decode($0)?.localIdentifier }
}

/// クラスタのメンバー refKey をクラウド（Dropbox）path 配列へ。人物アルバムのクラウドメンバー表示用。
public func cloudPaths(from refKeys: [String]) -> [String] {
    refKeys.compactMap { PhotoRef.decode($0)?.cloudPath }
}

// MARK: - Face avatar

/// 代表顔の写真からアバター（顔の切り抜き）を作る。`box` は Vision の正規化矩形（原点左下）。
/// **`box` が nil なら切り抜かず写真全体**を返す（ADR-91・レビュー画面の「写真全体」表示）。
/// 顔だけでは同一人物か判断できない場面（後ろ姿・小さい顔・似た兄弟）で、状況ごと見て判断できる。
public func loadFaceAvatar(coverRefKey: String?, box: CGRect?, maxPixel: CGFloat = 600) async -> UIImage? {
    guard let coverRefKey, let ref = PhotoRef.decode(coverRefKey) else { return nil }
    let source: CGImage?
    if let localID = ref.localIdentifier {
        source = await requestAspectCGImage(localID, maxPixel: maxPixel)
    } else if let path = ref.cloudPath {
        // クラウド顔: Dropbox の**キャッシュ済み**サムネから切り抜く（追加DL無し・ADR-88）。
        // ⚠️ 以前は `thumbnail(for:)` を呼んでおり、コメントの「追加DL無し」に反して未キャッシュなら
        //    ダウンロードを待っていた。グリッド（86k 枚）のサムネ要求で行列が飽和すると 1 件 10 秒級に
        //    なり、ピープルのアバターが延々出ない・レビュー画面が固まる原因になっていた（実測 diag-34）。
        //    アバターは「出なければ出ないでよい」情報なので、キャッシュに無ければ即諦める。
        let fetch = await MainActor.run { PeopleImageSources.cachedCloudThumbnail }
        if fetch == nil { await MainActor.run { PeopleImageSources.noteMissingCloudSource() } }
        if let cached = await fetch?(path) {
            source = PHAssetImageLoader.normalizedUpCGImage(cached)   // EXIF 回転を正規化（検出座標と同じ向きに）
        } else {
            // 次回の表示に間に合うよう温めておく（低優先・回線ポリシー内＝ADR-81）。
            await MainActor.run { PeopleImageSources.warmCloudThumbnail?(path) }
            source = nil
        }
    } else {
        source = nil
    }
    guard let cg = source else { return nil }
    // box なし＝写真全体をそのまま返す（切り抜きの計算をしない）。
    guard let box else { return UIImage(cgImage: cg) }
    let width = CGFloat(cg.width), height = CGFloat(cg.height)
    let margin: CGFloat = 0.35
    var b = box.insetBy(dx: -box.width * margin, dy: -box.height * margin)
        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    if b.isNull { b = box }
    let pixel = CGRect(
        x: b.minX * width,
        y: (1 - b.minY - b.height) * height,   // Vision(下原点) → CGImage(上原点)
        width: b.width * width,
        height: b.height * height)
        .integral
        .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    guard pixel.width >= 1, pixel.height >= 1, let cropped = cg.cropping(to: pixel) else { return nil }
    return UIImage(cgImage: cropped)
}

/// アスペクトを保った端末画像を取得する（顔矩形を重ねて表示するため正方クロップしない）。refKey 版。
public func loadLocalAspectImage(refKey: String, maxPixel: CGFloat = 1000) async -> UIImage? {
    guard let localID = PhotoRef.decode(refKey)?.localIdentifier,
          let cg = await requestAspectCGImage(localID, maxPixel: maxPixel) else { return nil }
    return UIImage(cgImage: cg)
}

/// アスペクトを保った**向き正規化済み** CGImage を取得する（顔矩形を正しくマッピングするため
/// 正方クロップしない）。実体は共通ローダ `PHAssetImageLoader`（顔検出の入力と同一経路）。
private func requestAspectCGImage(_ localIdentifier: String, maxPixel: CGFloat) async -> CGImage? {
    await PHAssetImageLoader.cgImage(localIdentifier: localIdentifier, maxPixel: maxPixel,
                                     contentMode: .aspectFit, allowsNetwork: true)
}
#endif
