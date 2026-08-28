# PhotoSourceKit

このファイルは **Packages/PhotoSourceKit/ を触るときだけ**読み込まれる（Claude Code のディレクトリ単位メモリ）。
root の `CLAUDE.md` には「どのパッケージが何を持つか」だけを置き、
**ファイル単位の詳細はここ**に置く——毎セッション全部を読ませないための分割。

⚠️ 横断的な規約（レイヤー分離・MainActor 既定隔離・記録の必須ルール・性能設計の原則・
i18n・テスト手順）は root の `CLAUDE.md` にある。こちらには**このパッケージ固有のこと**だけ書く。

## ファイル構成

```
Packages/PhotoSourceKit/           ← 写真ソース共通基盤（表示インターフェイス・純ロジック）
  Sources/PhotoSourceKit/          ← 責務ごとにサブフォルダで整理（すべて同一モジュール）
    Interface/                     PhotoItem / PhotoLoading（アイテム取得）/ PhotoStore(: PhotoLoading)/
                                   PhotoLoadState（権限/通信/完了/失敗の状態 enum）/
                                   PhotoInsight（フル画像の付加情報＝表示タグ・人物・解析状態。SwiftUI 非依存値型）
    Views/                         PhotoSourceContentView（状態分岐＋全状態に下部 Home/Settings バー）/
                                   PhotoGridView / PhotoCollectionView（UICollectionView グリッド・diffable・プリフェッチ・
                                   contentOffset ベースのスクラバー）/ GridThumbnailCell / GridSectionHeaderView /
                                   GridScrubberView / FullPhotoView / PhotoInfoPanel / PhotoPageView /
                                   ZoomableImageView（ピンチ/ダブルタップ拡大＋ZoomMath 純計算・ADR-77）/
                                   PhotoSourceEnvironment（dismissToHome / showSettings）/ GridSettingsKeys
    Places/                        GeoGridKey(純)/ PlaceAlbumInfo / PlaceGrouping(純)/
                                   PlaceNameResolver(actor・**オフライン**地名解決 + 地名キャッシュ)/
                                   OfflinePlaceDB(同梱 cities15000.bin で最近傍逆ジオコーディング・ネット不要)
    Support/                       PhotoGridGrouping(日付グルーピング純)/ PhotoItemSorting(純)/
                                   PhotoExifInfo(EXIF 解析+parse 純)/ JSONFileStore<T>(JSON 永続化)
  Tests/PhotoSourceKitTests/       grouping/sorting/exif/geo/jsonstore/place の単体テスト（macOS）

```
