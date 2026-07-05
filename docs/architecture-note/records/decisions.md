# 設計判断の記録（ADR）— マスター

> このファイルが**設計判断の正本（マスター）**です。HTML（`docs/architecture-note/design-decisions/adr.html`）は、ここから必要なものを選んで記載した派生物であり、全件を転記するとは限りません。
>
> **運用ルール**
> - 設計上の判断をしたら、必ずこのファイルに 1 項追記する（網羅）。
> - HTML へ載せるかは別途指示で決める（取捨選択）。
> - フォーマット: `## ADR-N タイトル` ＋ **文脈 / 決定 / 結果（トレードオフ）**。番号は連番。
> - 撤回・変更時は項を消さず「状態: 置換（→ ADR-M）」のように追記して経緯を残す。

## テンプレート

```
## ADR-N タイトル
- 状態: 採用 / 置換(→ADR-M) / 廃止
- 文脈: なぜ判断が必要か。
- 決定: 何を選んだか。
- 結果: 得たもの／トレードオフ。
- 関連: コミット・ファイル・関連 ADR/事例。
```

---

## ADR-1 検索を語彙ゼロのオープン語彙 CLIP に一本化
- 状態: 採用
- 文脈: 固定タグ方式は語彙外検索に弱く、辞書の保守も負担。
- 決定: 固定語彙・OCR を捨て、CLIP のオープン語彙＋構造化条件＋字句の RRF 融合にする。
- 結果: 自由なクエリに強い。代わりに全写真の画像埋め込み（背景処理）が必要。表示タグだけは別途ゼロショットで出す。
- 関連: `AutoAlbumCore/AIAlbum/`、`MobileCLIPKit/`。

## ADR-2 写真ソースを共通プロトコルに統一
- 状態: 採用
- 文脈: 端末・Dropbox・統合で同じ閲覧体験を出したい。
- 決定: `PhotoStore` / `PhotoItem` / `PhotoLoadState` に揃え、共通ビューを共有。
- 結果: 新ソースを足しても表示側は不変。各ソース固有の init パラメータは維持。
- 関連: `PhotoSourceKit/Interface/`。

## ADR-3 ロジック層 / UI 層の分離（Core/UI）
- 状態: 採用
- 文脈: 副作用（PhotosKit/URLSession/SwiftData）を UI から切り離してテストしたい。
- 決定: `*Core`（SwiftUI 非依存）と `*Kit`（UI・`@_exported import`）に分割。
- 結果: 純ロジックを macOS で高速テスト。import は 1 つで済む。パッケージ数は増える。

## ADR-4 グリッドを UICollectionView に置換
- 状態: 採用
- 文脈: 6 万件で `LazyVGrid` + `scrollTo` のスクラバーが不安定。
- 決定: `UIViewRepresentable` で UICollectionView（diffable・プリフェッチ・contentOffset スクラバー）を採用。
- 結果: 大ジャンプが安定。UIKit のボイラープレートが増える。
- 関連: コミット 9897653、事例「スクラバー不具合」。

## ADR-5 単一 fullScreenCover + enum で遷移
- 状態: 採用
- 文脈: 複数の `.fullScreenCover(item:)` 併用で提示競合し、別アルバムの中身が出る不具合。
- 決定: 遷移先を単一の `HomeDestination` enum にまとめ、`.fullScreenCover` は 1 つに。`.sheet` も同様に統合。
- 結果: 競合解消。分岐は `switch` に集約。
- 関連: `MosaicPhotos/HomeView.swift`、事例「アルバムが無関係な写真になる」。

## ADR-6 CLIP 埋め込みを別テーブル + Float16
- 状態: 採用
- 文脈: 埋め込みを `PhotoEnrichment` に inline 格納していたため、全件 fetch のたびに 138MB 級 blob を展開し、写真の多い実機で起動クラッシュ。
- 決定: 埋め込みを `PhotoEmbedding` 別テーブルへ分離し、Float16 で保存。メタデータ fetch は blob に触れない。
- 結果: 常駐が「ページ 1 枚分」に。スキーマ再構築（`AutoAlbumV10`）が必要。
- 関連: コミット f84529c、事例「メモリ枯渇」。

## ADR-7 ModelContainer を自己修復で構築
- 状態: 採用
- 文脈: SwiftData は破損・不整合で起動時 trap し、実機で原因不明クラッシュ。
- 決定: `makeResilientContainer` で「削除→再試行→インメモリ」とフォールバック。
- 結果: 起動を止めない。最悪データは失うが回復する。
- 関連: コミット 7e53db3。

## ADR-8 起動の重いストア構築を非同期化
- 状態: 採用
- 文脈: `HomeView.init` が同期で `ModelContainer` を作り、最初の描画をブロック。
- 決定: `RootView` が `HomeStores.build()` で非同期構築し、1 秒超でローディング表示。
- 結果: 体感起動が改善。
- 関連: コミット 8bc97dd、事例「起動の高速化」。

## ADR-23 AI アルバムの解釈は「作成時に 1 回・永続化」（カタログ追従の再解釈を廃止）
- 状態: 採用（旧方式＝カタログ署名によるキャッシュ全破棄を置換）
- 文脈: 旧方式は「解釈の正しさはライブラリの語彙（カタログ＝地名/人物一覧）に依存する」前提で、カタログ署名（件数ベース）が変わるたび解釈キャッシュを全破棄し LLM で再解釈していた。署名はメモリのみのため**毎起動で必ず全アルバム再解釈**（実測 9.4s のメインハング）となり、写真が増え続ける・アルバムを多数作る運用では原理的に破綻する。
- 決定: **解釈（検索文 → QuerySpec・英訳）は検索文の性質**と再定義し、作成/編集時に 1 回だけ LLM 実行して `AIAlbumInterpretationStore`（JSONFileStore・SwiftData スキーマ変更なし）へ永続化。存在しない地名・人名が解釈に残ることを許容する（照合は部分一致なので、該当写真が索引され次第自動的に当たる）。相対日付は相対形のまま保存し評価時に解決。LLM 呼び出し（解釈・翻訳）は Task.detached で完全オフメイン化。再評価は (1) 増分＝新規埋め込み分だけ採点してスコアプール（上位300・永続）へマージ、(2) ドリフト検知＝評価済み枚数の差が閾値（500）超でアイドル時にフル再評価、の 2 経路。起動時の再評価は廃止（保存済みメンバーを即表示）。
- 結果: 起動時の LLM 実行ゼロ（ハング根治）。写真追加のコストが O(全体)→O(新規)。アルバム数が増えても LLM は作成時の 1 回のみ。トレードオフ: 増分評価では lexical（地名/人物の字句）変化は反映されずフル再評価待ち。カタログ由来の表記寄せは作成時のヒントに限定される。
- 関連: `AIAlbumInterpretationStore.swift` / `AIAlbumService.swift` / `AIAlbumSearch.swift`（searchWithPool / mergePool / memberKeys＋テスト）/ `PhotoTagger.swift`（onBatch が新規 refKeys を通知）/ `AutoAlbumEngine.swift`（ドリフト検知）。事例「起動時に設定画面が固まる（FM 再解釈 9.4s）」。

## ADR-22 撮影日時のサニタイズは表示層でなくデータ入口で行う
- 状態: 採用
- 文脈: EXIF 欠落・0 値・カメラ既定値（1970/1980 等）の写真が「1980-01-01」等として表示・整列される。当初は表示3箇所（フル画面ラベル・アルバム日付・グリッド見出し）だけで `meaningful` 判定して「日時不明」化したが、ソート（`PhotoItemSorting`）・自動アルバム生成（`PhotoEnrichment` の保存値）・場所スキャンは生値のままで、無意味な日付が並び順や旅行アルバムの日付に混ざり続けた。
- 決定: 判定の核を `MosaicSupport.CaptureDate.meaningful`（有効窓 1990-01-01〜現在+2日）に置き、**データの入口**でサニタイズする：`LocalPhotoItem.captureDate`（PHAsset）・`DropboxFileItem.init`（同期パース／キャッシュ復元の両生成点を一括）・`PhotoEnricher`（エンリッチ保存値）。表示層の `DisplayDate.meaningful` は委譲にして防御としては残す。
- 結果: ソート・生成・グルーピングにも無意味な日付が入らない。入口が1関数に集約され閾値変更が1箇所。トレードオフ: 1990 年より前の正当なスキャン写真も「日時不明」になる（スマホ写真アプリの用途では許容）。既存の生成済みアルバムは再生成するまで旧日付が残る。
- 関連: `MosaicSupport/CaptureDate.swift`（+テスト）、`DropboxFileItem.swift` / `PhotoEnricher.swift` / `LocalPhotoItem.swift`。

## ADR-21 逆ジオコーディングを同梱DBで完全オフライン化（GeoNames cities15000）
- 状態: 採用
- 文脈: 座標→地名の解決を `CLGeocoder`（オンライン・レート制限・要ネットワーク）で行っていた。一括生成時にスロットリングで失敗し、`PlaceNameResolver` が**失敗（空）を恒久キャッシュ**するため旅行アルバムが「Trip」で固定化、Places も地名にならない不具合が出ていた（[[ADR-1]] 系の自動アルバム品質に影響）。
- 決定: GeoNames `cities15000`（約3.4万都市・CC BY 4.0）から生成したコンパクトなバイナリ `cities15000.bin`（約0.8MB）を `PhotoSourceKit` に同梱し、`OfflinePlaceDB` が**最近傍検索**で市区町村/都道府県/国を返す（`scripts/build_places.py` で生成、リトルエンディアン：lat/lon の f32 配列＋行政区/国プール＋都市名）。`PlaceNameResolver` のバックエンドをこれに置換し `CLGeocoder` を廃止。結果は決定的なのでグリッドキャッシュ（GeoGridKey）はそのまま安全に永続化できる。地名は**英語(ローマ字)と日本語の両方**を bin に保持し、アプリの表示言語（`AppLocale.isJapanese`＝上書き言語または端末言語）で切り替える（日本語が無い都市は英語へフォールバック）。英語＝GeoNames `name`、日本語＝言語別別名 `alternateNamesV2`（isolanguage=ja）。例 日本語: 千代田区/東京都/日本・パリ/フランス、英語: Chiyoda/Tokyo/Japan・Paris/France。
- 結果: ネット問い合わせ**ゼロ**・即時・無制限・失敗なし。アルバム命名と Places の両方が安定（「Trip」固定が解消）、命名が同期化して非同期スロットリングも不要に。**UI 言語に追従**して日/英で表示（`PlaceNameResolver` のキャッシュも言語別キー）。トレードオフ＝精度は「最も近い既知都市」（用途的に十分。都道府県・国は堅牢）、日本語名の無い一部の海外マイナー都市はローマ字。bin は日英両方で約1.2MB（CLIP 約60MB に比べ微小）。CC BY 4.0 を NOTICE/アプリ内 Licenses に表記。
- 関連: `PhotoSourceKit/Places/OfflinePlaceDB.swift`・`PlaceNameResolver.swift` / `scripts/build_places.py` / `Packages/PhotoSourceKit/Package.swift`(resource) / `NOTICE`・`Licenses`。

## ADR-20 メモリ圧迫対応を中枢へ集約（解放ハンドラ登録＋詳細ログ＋履歴）
- 状態: 採用
- 文脈: メモリ節約後も実機で起動直後クラッシュ（jetsam）が起きていた。圧迫検知は `DispatchSource` にあったが「フラグ＋ログ」止まりで、画像キャッシュの解放は別系統（UIKit の `didReceiveMemoryWarning`）頼みのため、DispatchSource の critical では解放まで繋がらず、warning でも"上限半減"止まりだった。「圧迫時にログを出し・メモリを解放し・クラッシュを避ける」を一本化したい。
- 決定: `MosaicSupport.MemoryPressureMonitor` を中枢化する。(1) `register(_:) -> token` で**解放ハンドラ**を登録できるようにし、(2) `handle(level:)` が圧迫フラグ設定・履歴記録・**全ハンドラ呼び出し**・診断ログ追記（レベル／footprint／端末RAM／ハンドラ数）を一括実行。`Diagnostics` の DispatchSource は `handle(.warning/.critical)` を流すだけにする。`MemoryImageCache` は `register` で **warning=上限半減（LRU 縮小）／critical=即時全消去（`removeAllObjects`）** を解放する（ImageCacheKit が MosaicSupport に依存）。背景 CLIP 埋め込みは従来どおり `isUnderPressure` で一時停止。Developer Options（`MemoryDebugSection`）に**累計回数＋直近イベント履歴**（時刻・レベル・footprint）を表示。CLIP モデルのアンロードと footprint 常時監視は今回スコープ外（再ロード遅延・常駐コスト）。
- 結果: 圧迫イベントが単一経路で「ログ→解放」に直結。critical で素早くメモリを返し jetsam 余地を減らす。履歴で実機の前兆を切り分け可能。トレードオフ＝critical 全消去後はサムネ再デコードが一時的に増える（30秒で上限復帰）。
- 関連: `MosaicSupport/Diagnostics.swift`（MemoryPressureMonitor）/ `ImageCacheKit/MemoryImageCache.swift` / `MosaicPhotos/Settings/MemoryDebugSection.swift`。E1 段階縮小（[[ADR-15]] 電源ゲート・背景処理停止）と併用。

## ADR-19 同梱 CLIP モデルを OpenCLIP ViT-B-32/DataComp（MIT）へ差し替え（権利フリー化）
- 状態: 採用
- 文脈: MobileCLIP-S2 の重みが Apple ML Research Model License（研究目的限定・商用不可）で AGPL／App Store 配布に使えない（[[ADR-18]] の残課題）。許容ライセンスのモデルへ差し替える。
- 決定: **OpenCLIP `ViT-B-32` / `datacomp_xl_s13b_b90k`（重み・コードとも MIT）** を採用。汎用変換 `scripts/convert_clip.py`（open_clip→Core ML、**CLIP mean/std をモデル内に内包**して ImageType は scale=1/255 のまま＝アプリ無改修、画像 fp16／テキスト fp32）で変換し、`build_mobileclip.sh` を更新。同梱ファイル名（`MobileCLIP*` / `MobileCLIPKit` / `mobileclip_config.json`）は互換のため**据え置き**（中身は OpenCLIP）。Swift は `MLImageConstraint` による自動リサイズ＋正規化内包のため**無改修**（imageSize 256→224 は config 経由）。CLIP BPE 語彙・`CLIPTokenizer` は同一で流用。`perceptionVersion` を 7 に採番し**全写真を再埋め込み**。
- 検証（認識率ハーネス・ImageNet-1k ゼロショット top-1・200枚・CPU／クエリ 10件）:
  - MobileCLIP-S2（研究限定）= **81.0%**、ViT-B-16/datacomp = 75.0%、**ViT-B-32/datacomp = 75.0%（採用）**、ViT-B-32/openai = 64.5%。クエリは全候補 10/10。
  - TinyCLIP は open_clip 非対応（独自アーキ・config 無し）でこのツールチェーンではロード不可のため候補から除外。
  - 採用は**軽量（patch32・画像 enc ~60MB）かつ 75%** の ViT-B-32/datacomp（オンデバイス速度/省電力との両立）。MobileCLIP 比で約 -6pt だがクエリ性能は同等。
- 結果: **MIT 化で AGPL＋App Store（デュアル）の最後の障害が解消**。NOTICE/README/アプリ内 Licenses を OpenCLIP へ更新し研究限定の警告を撤去。モデル本体は `.gitignore` 対象でローカル生成（`build_mobileclip.sh`）。
- 関連: `scripts/convert_clip.py` / `scripts/build_mobileclip.sh` / `scripts/eval_recognition.*` / `AutoAlbumEngine`(perceptionVersion) / `Licenses.swift`・`LicensesView.swift` / `NOTICE` / `README`。

## ADR-18 ライセンス：ソース AGPL-3.0＋デュアル配布（App Store は著作権者が Apple 条件で）／第三者はアプリ内表示
- 状態: 採用（経緯: 当初 AGPL 採用 → 一旦撤回 → **デュアル方式で再採用**）
- 文脈: 配布形態は「**アプリ＝App Store／ソース＝GitHub**」。本体ライセンスを定めつつ、GPL/AGPL × App Store の非互換を回避したい。
- 決定: ソースは **AGPL-3.0-or-later**（`LICENSE` に公式全文・原文）。**デュアル配布**＝著作権者（単独）は同一成果物を App Store では Apple 標準条件で配布できる（AGPL は他者ライセンシーを縛るが著作権者自身は別条件で配布可）。第三者依存は MIT/BSD で両立可。将来コントリビュートで縛られないよう **`CONTRIBUTING.md` に DCO＋再ライセンス許諾**、宣言を `NOTICE` に明記。アプリ内「Settings → Licenses」に本アプリ(AGPL/デュアル)と第三者資産を表示。§7 例外方式は不採用（例外が全員に及ぶため。自分だけが App Store 配布するデュアルが適切）。
- 結果: ソース公開（AGPL）と自分の App Store 配布が両立。**未解決の前提**: MobileCLIP の**重みは研究目的限定・商用不可で App Store 不可**のため、バンドル出荷前に**許容ライセンスのモデル（OpenCLIP の MIT/Apache 等）へ差し替え**が必要（別タスク）。例外条項では解けない。
- 関連: `LICENSE` / `NOTICE` / `CONTRIBUTING.md` / `MosaicPhotos/Settings/Licenses.swift`・`LicensesView.swift` / README。
- 文脈: 公開にあたり本アプリのライセンスを定め、使用ライブラリ/資産の必要な帰属表示を行いたい。
- 決定: 本体を **AGPL-3.0-or-later** とし、リポジトリ直下に公式全文の `LICENSE`（原文のまま・翻訳しない）を設置。アプリは第三者の Swift ライブラリ依存ゼロ（全ローカルパッケージ）。同梱/使用する第三者資産を **設定 → Licenses**（`LicensesView`＋データ `Licenses.swift`）で一覧表示：本アプリ(AGPL)/同梱(MobileCLIP=Apple・CLIP 語彙/トークナイザ=MIT)/Apple(SDK・SF Symbols)/ビルドツール(coremltools=BSD3・PyTorch=BSD3・open_clip=MIT・ml-mobileclip=Apple・Pillow=HPND・NumPy=BSD3)/ドキュメント(Mermaid=MIT)。MIT/BSD3/HPND は正確なテンプレートで生成、Apple/PyTorch は告知＋upstream リンク。**ライセンス本文は英語原文のまま**、画面の枠・用途説明のみ日本語化。
- 結果: 帰属を満たしつつアプリ内で確認可能。AGPL によりソース公開義務（GitHub 公開で充足）。第三者ライブラリ追加時は `Licenses.swift` に1項追加する運用。
- 関連: `LICENSE` / `MosaicPhotos/Settings/Licenses.swift` / `LicensesView.swift` / `SettingsView.swift`。

## ADR-17 UI 国際化を String Catalog で（base=英語・per-package・日本語追加・アプリ内言語切替）
- 状態: 採用（全 UI パッケージ＋アプリ本体・日英・言語切替つき）
- 追補（全パッケージ化＋言語切替）: `PhotoSourceKit`/`LocalPhotoKit`/`DropboxKit`/`BackupKit` をすべて per-package で日本語化（`PhotosFeatureKit` は UI 文字列なし）。各パッケージは `L(_:)=AppLocale.string(_:bundle:.module)` を使う。**アプリ内言語切替**は `MosaicSupport.AppLocale`（`overrideCode` と `string(_:bundle:)`）＋`AppLanguage`（system/ja/en）で実現：設定 → General の「Language」ピッカー（既定 **System**＝端末が日本語なら日本語・それ以外は英語）。`RootView` が `.environment(\.locale,)` でアプリ本体 `Text` を、`AppLocale.overrideCode` で各パッケージ `L()` を同時に切り替える（端末設定に依らず日英を即切替）。`MosaicPhotosApp.init` で `AppLocale.loadFromDefaults()`。検証: 端末ビルドで `ja.lproj` が **アプリ＋4 パッケージバンドル**すべてに生成、`swift test` 通過。残: Developer/Debug は英語のまま（対象外）、`PhotoLoadState`/エラー文等の動的 String（`Text(変数)`）は英語フォールバック。
- 追補2（可視部分の総ざらい）: アプリ本体で **String 変数として渡るため未訳だった値**（ソース行の「All Photos」「Cloud」「On-Device Photos」やサブタイトル・`navigationTitle(title)`・件数 `%lld photos`(複数形)・「No matches」等）をアプリ用 `L(_:)=AppLocale.string(_:bundle:.main)` で包んで日本語化。設定の**ヘルプ/フッター文**も翻訳（`Text("a" + "b")` の連結フッターは verbatim で未訳になるため単一リテラル化して翻訳）。エラーメッセージは対象外。アプリのカタログは ja 115 件をコンパイル確認。
- 文脈: UI 文字列は元々すべて英語ハードコード（base 言語が揃っている）。国際化したいが UI が多数のパッケージに分割されている。
- 決定: **String Catalog（`.xcstrings`）** を採用、base=英語。**案A（per-package）**：各 UI パッケージに `Localizable.xcstrings` を置き `Package.swift` に `defaultLocalization: "en"` ＋ `resources: [.process("Localizable.xcstrings")]`（**SwiftPM CLI は `.xcstrings` を自動認識しないため明示宣言が必須**＝これが無いと `Bundle.module` 生成されず `swift test` が落ちる）。パッケージ内は `Text("x")` が既定で `Bundle.main` を見る問題を避けるため、`String(localized:bundle:.module)` を包む小ヘルパー **`L(_:)`** で全 API（Text/Label/Button/Section/navigationTitle 等は String を verbatim 表示）を一様にローカライズ。アプリ本体は `Text("x")` リテラルが既定で `Bundle.main` を見るのでコード改変不要、`MosaicPhotos/Localizable.xcstrings` を置き、`project.pbxproj` の `knownRegions` に `ja` 追加。**Developer Options/Debug は対象外（英語のまま）**。翻訳は機械翻訳。キー不一致は英語にフォールバック（安全）。
- 結果: 端末ビルドで `ja.lproj`（アプリ本体＋`PhotoSourceKit_PhotoSourceKit.bundle` 双方）が生成され日本語化を確認。`swift test`（macOS）も通過。残：他 UI パッケージ（LocalPhotoKit/DropboxKit/PhotosFeatureKit/BackupKit）と動的 String（`PhotoLoadState` メッセージ等＝`Text(変数)` は verbatim で未翻訳）の対応は後続バッチ。日付/数値/地名はロケール対応（概ね自動）。
- 関連: `PhotoSourceKit`（`Localization.swift`＝`L()`・`Localizable.xcstrings`・`Package.swift`）/ `MosaicPhotos/Localizable.xcstrings` / `project.pbxproj`（knownRegions）。

## ADR-16 バックグラウンドの「通信」を回線種別でゲート（Wi-Fi 優先・段階設定）
- 状態: 採用
- 文脈: 電源ゲート（[[ADR-15]]）に加え、背景処理のうち**通信を伴うもの**（Dropbox 同期・バックアップ upload・クラウド写真の CLIP 埋め込み＝サムネDL・逆ジオコーディング）をデータ通信量の観点で制御したい。Wi-Fi のときだけにしたい＋何段階か選びたい。ユーザーが**閲覧中に行う取得**（サムネ/フル画像）は前景操作なので止めない。
- 決定: `MosaicSupport.NetworkStateMonitor`（`@MainActor @Observable`・`NWPathMonitor` 内包・電源/メモリ系モニタと同列・UIKit 非依存）を新設。`isReachable`/`isOnWiFi`(wifi||有線)/`isExpensive`/`isConstrained`(低データ) を監視し、ポリシー `BackgroundDataPolicy`（unrestricted / **wifiOnly=既定** / wifiNoLowData / off・キー `NetworkStateMonitor.policyKey`）と合わせ `networkAllowed()` を返す。通信を使う背景処理は **`backgroundAllowed()`（電源）かつ `networkAllowed()`（回線）** で実行。CLIP 埋め込みは**スマート方針**＝回線NG時は `unembeddedRefKeys(limit:localOnly:)` で**クラウド分をスキップしローカルだけ続行**、ローカルが尽きたら終了し、電源/回線の復帰（`onChange`）で `scheduleBackgroundFill()` を再起動してクラウド分を拾い直す。設定は General の `BackgroundSettingsView` に「Background Data」4段階を電源の隣へ。可視化はアクティビティバーに回線チップ（Wi-Fi 緑 / 保留 橙 / Off・圏外 灰）を電源チップの隣に追加（[[ADR-14]]）。
- 結果: 既定でセルラーの背景通信を避けつつ、ローカル AI 処理はセルラーでも進み、Wi-Fi でクラウド分が再開。閲覧時取得は常に行う。トレードオフ: 既定で全ユーザーが「Wi-Fi のみ」に変わる（セルラーでは同期・バックアップ・クラウド埋め込みが保留）。`localOnly` 絞り込みは `refKey.starts(with:"L-")` の SwiftData 述語に依存。
- 関連: `MosaicSupport/NetworkStateMonitor.swift` / `AutoAlbumCore`（`PhotoTagger.embedUnprocessed`・`AutoAlbumStore.unembeddedRefKeys(localOnly:)`・`scheduleBackgroundFill` を public 化）/ `HomeView.swift`（evaluateSync・resumeBackgroundWork・place ループ）/ `BackupKit/BackupEngine.swift` / `MosaicPhotos/Settings/BackgroundSettingsView.swift` / `DropboxKit/DropboxActivityBar.swift`。

## ADR-15 バックグラウンド処理を電源状態でゲート（電池節約）
- 状態: 採用
- 文脈: 継続的なバックグラウンド処理（特に CLIP 背景埋め込み＝ANE/GPU 推論＋クラウドサムネDL、Dropbox 差分同期、定期再生成/場所スキャン、バックアップ）が電池を消費する。電源接続時だけ走らせたい。
- 決定: 横断モニタ `MosaicSupport.PowerStateMonitor`（`@MainActor @Observable` シングルトン・`MemoryPressureMonitor` と同系列）を新設。`UIDevice.batteryState`＋`ProcessInfo.isLowPowerModeEnabled` と各通知を監視し、設定ポリシー（`BackgroundPowerPolicy`: whileCharging / always / off・キー `PowerStateMonitor.policyKey`・**既定 whileCharging**）と合わせて `backgroundAllowed()` を返す。whileCharging は「電源接続(charging/full) かつ 低電力モード OFF」。ゲート対象（スコープ最大）: CLIP 背景埋め込み（`shouldPause` に `!backgroundAllowed` を追加＝電源復帰で自動再開）/ 自動アルバム定期再生成（`refreshIfNeeded` の guard）/ 場所の定期再スキャン（Home のループで guard）/ Dropbox 差分同期（電源変化で `startSync`/`stopSync`）/ バックアップアップロード（ファイル間で一時停止→電源復帰で再開）。設定 UI は**アプリ横断のため設定ルートの General に独立**（`BackgroundSettingsView`「Background & Battery」3択）。当初 Albums 配下に置いたが、機能横断（同期/AI/スキャン）に効くので General へ移設。
- 結果: 電池中は重い背景処理が止まり、電源接続で自動再開。初回起動の一回限りの読み込み・生成・キャッシュ表示は妨げない（継続/定期処理のみゲート）。トレードオフ: 既定で全ユーザーが「充電中のみ」に変わる（クラウド一覧は電池中は更新されない）。手動バックアップも電池中はファイル間で一時停止する（ログに明示）。ポリシー変更は埋め込み/ループには即時、Dropbox 同期は次の電源変化/再起動で反映。電源状態と背景処理の稼働は ADR-14 の[[アクティビティバー]]に可視化（電源チップ＋背景ランプ）。なお `UIDevice.batteryState` はシミュレータや判定不能時に `.unknown` を返すため、`charging/full` のみで判定すると背景処理が全ゲートで止まる（シミュレータでランプがグレーのまま）。**`.unplugged` と確定したとき以外は電源扱い**（`.unknown` は電源扱い）にしてロックを避ける。
- 関連: `MosaicSupport/PowerStateMonitor.swift` / `AutoAlbumCore`（`AutoAlbumEngine+Recognition`・`AutoAlbumEngine.refreshIfNeeded`）/ `HomeView.swift`（evaluateSync・place ループ）/ `BackupKit/BackupEngine.swift` / `MosaicPhotos/Settings/BackgroundSettingsView.swift`。

## ADR-14 Dropbox 通信アクティビティの可視化（スロット LED インジケータ）
- 状態: 採用
- 文脈: Dropbox 通信が「今どれだけ並行して動いているか」が見えず、サムネイル先読みの遅延（事例「ポツポツ」）の切り分けが体感頼みだった。各並列スロットの稼働状況を端末上で直接観察したい。
- 決定: 横断的なライブ計測 `DropboxActivityMonitor`（`@MainActor @Observable` シングルトン・`Diagnostics`/`LogChannel` と同系列・**UIKit 非依存**＝macOS テスト維持）を新設し、各チャンネルが報告する: サムネイル（容量=`maxConcurrentRequests`／稼働スロット=in-flight バッチ本数／先読み待ち枚数）は `DropboxThumbnailBatcher`、同期は `DropboxPhotoStore.syncState` の `didSet`、フル画像 DL は `fullImage`/`originalImageData` を begin/end で計測、バックアップ upload は `BackupEngine.phase` の `didSet`。UI は `DropboxKit.DropboxActivityBar`（**形＝チャンネル／色＝状態（灰=待機・青=通信・緑=監視・赤=失敗）／数・塗り＝強度**）で、サムネイルは同時実行スロットをレーン（ピップ）表示。表示は **Dropbox 通常設定（`DropboxSettingsView`）の「Show activity bar」トグル（既定 ON・キー `DropboxActivitySettingsKeys.showBar`）** で制御し（デバッグ機能ではなく通常機能と位置づけ）、`View.dropboxActivityBar()` を `HomeView`/`SourceHostView` 最上部へ重ねる（`allowsHitTesting(false)` で素通し）。
- 結果: スロットの稼働本数・先読みキュー深さ・同期/DL/upload の同時状況が一目で分かり、並列化や並列数設定（`thumbnailConcurrency`）の効果を実機で確認できる。報告は MainActor 上の Int/enum 代入のみで軽量（表示 OFF でも常時更新）。fullScreenCover は別ビューツリーのため最上部表示は各ホストへ個別適用が必要。
- 追補（バー統合・電源/背景処理の可視化）: 同じ 1 行のバーに **電源ゲート（`PowerStateMonitor`）** と **バックグラウンド処理（`BackgroundActivityMonitor`）** を統合した。左端に電源チップ（稼働可=緑⚡／電池待ち=橙／Off=灰）、Dropbox クラスタの右に背景ランプ（AI 埋め込み＝残り枚数併記・自動アルバム生成・場所走査・アルバム走査、稼働中はパルス）。背景の状態は `AutoAlbumEngine` の `isTagging`/`isGenerating`/`isGeneratingPath` の `didSet` と埋め込み進捗コールバック、`PlaceScanner`/`LocalAlbumScanner` の `isScanning`（app 層で橋渡し）が `BackgroundActivityMonitor`（MosaicSupport・@Observable）へ報告する。これで [[ADR-15]] の電源ゲートにより「なぜ背景処理が止まっているか（電池待ち）」も一目で分かる。`DropboxKit` に `MosaicSupport` 依存を追加。
- 関連: `Support/DropboxActivityMonitor.swift` / `MosaicSupport/BackgroundActivityMonitor.swift` / `MosaicSupport/PowerStateMonitor.swift` / `Store/DropboxThumbnailBatcher.swift` / `Store/DropboxPhotoStore.swift` / `BackupKit/BackupEngine.swift` / `DropboxKit/DropboxActivityBar.swift`、事例「ポツポツ」（[case-studies]）。

## ADR-13 フォルダ名アルバムに日付抽出を追加（名前＋年でグループ）
- 状態: 採用
- 文脈: Dropbox フォルダ名アルバムは名前しか取り出せず、日付（多様な表記）を活かせていなかった。クラウド写真は EXIF 日付を欠くことも多い。
- 決定: `FolderDateParser`（純・テスト）で多様な表記を粒度つき期間 [start,end] に正規化（ISO/圧縮/和暦/月名/範囲、曖昧な数値日付は端末ロケールで解決、12超は日と確定）。`PathAlbumStrategy` はパスのフォルダ部から日付を取り、**名前＋年でグループ（年違いは別アルバム）**、アルバム期間にフォルダ日付を採用（無ければ EXIF）。表示は「名前 (年)」（名前に年が含まれれば付けない＝**名前から日付は除去しない**）。
- 結果: 「Hawaii (2023)」「Hawaii (2024)」のように年で分かれ、EXIF 日付が無くても期間が付き、日付ソート/AI 日付検索に効く。曖昧日付はロケール依存（プレビュー前提）。範囲のハイフン区切り等は今後拡張余地。
- 関連: `Strategies/FolderDateParser.swift` / `PathAlbumStrategy.swift`。

## ADR-12 AI アルバム検索を合成可能な QuerySpec（OR/NOT/多ファセット）へ拡張
- 状態: 採用（フラットな `AIAlbumQuery` の AND 専用を一般化。`AIAlbumQuery` は後方互換で残す）
- 文脈: 「ここ2年の子供」「京都か奈良の家族のお気に入り、スクショ除く」等、アプリが持つ多様な情報（日付/場所/人物/人数/向き/位置/ソース/内容）への複雑条件・OR・NOT を柔軟に組みたい。
- 決定: DNF（節の OR・節内 AND・各条件 NOT 可）の `QuerySpec`/`QueryClause`/`Condition` を新設。ハード条件（日付/場所/人物/人数/ソース/お気に入り/スクショ/向き/位置）は `QueryEvaluator` で評価、内容語(content)は CLIP でソフト採点（`AIAlbumSearcher.search(baseLite:spec:)`）。相対日付は `RelativeDateParser`（日英）で FM 非対応端末でも解釈。Foundation Models は `GeneratedSpec`（Generable・clauses=OR）で出力、RuleBased はフラット解釈を単一節へ橋渡し。`AIAlbumService` は `interpretSpec` 経由に配線。
- 結果: 相対日付・複数ファセット・**OR を再投入**。回帰（全滅）対策を二重化: (1) FM スキーマから人数(peopleAtLeast)・位置(hasLocation)を**廃止**し、人物の有無・概念は内容(content=ソフト)で扱う／日付は妥当範囲のみ採用（`sanitizedDate`）。(2) `AIAlbumSearcher` に**安全網**＝ハード条件で base が全滅しても意味の意図があれば内容のみへ緩和（ただし緩和時にヒット0なら空を返し全件は出さない）。これで「データで満たせないハード条件」での全滅を防ぐ。除外内容(not(content))の減点・多ソース日付（旅行アルバム由来）は後続。
- 関連: `AIAlbum/QuerySpec.swift` / `QueryEvaluator.swift` / `RelativeDateParser.swift` / `AIAlbumSearch.swift` / `FoundationModelsQueryUnderstanding.swift` / `AIAlbumService.swift`。

## ADR-11 CLIP 画像エンコーダを fp16 のみにする（実機 ANE 優先）
- 状態: 採用（旧「fp32（シミュレータ NaN 回避）」を置換）
- 文脈: 実機ログで画像埋め込みが 1 枚 0.5〜1.3 秒と遅い。原因は画像エンコーダを `compute_precision=FLOAT32` で変換していたため、Neural Engine(ANE) に載らず GPU/CPU フォールバックしていたこと。元の fp32 はシミュレータの NaN 回避が目的だったが、シミュレータ最適化は本末転倒。
- 決定: `convert_mobileclip.py` の画像エンコーダ変換を `FLOAT16` にする（実機 ANE 対応＝高速化）。fp16 はシミュレータで NaN 化し得るが、ランタイムの有限性チェックが nil に落として安全に無効化する。`ImageRecognitionTests` の画像タワー依存テストはシミュレータでスキップし実機検証に寄せる。
- 結果: 実機の埋め込みが ANE 実行で高速化する見込み（要・実機実測）。シミュレータでは画像 CLIP が無効化され得る（テキスト系は不変）。モデルは `build_mobileclip.sh` の再実行で再生成が必要。
- 関連: `scripts/convert_mobileclip.py`、`MobileCLIPRuntime`（simulator `.cpuOnly` / 実機 `.all`）、事例「CLIP 埋め込みが遅い」。

## ADR-10 GitHub を CI・公開・リリースに活用
- 状態: 採用
- 文脈: 個人開発でも回帰検知・設計資料の公開・タグ運用の自動化が欲しい。秘密の誤コミットも機械的に防ぎたい。
- 決定: GitHub Actions で CI（`scripts/test.sh fast` を gate、iOS sim は best-effort）/ Pages で `docs/architecture-note` を公開 / タグ push で Release 自動生成。リポジトリ設定で Secret scanning + Push Protection を有効化。CodeQL は **default setup の autobuild が Xcode+SPM 構成で失敗**するため、`build-mode: manual` の advanced ワークフロー（CI と同じ `xcodebuild -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO`）に切替（`.github/workflows/codeql.yml`）。なお `DropboxSecrets.swift`（appKey・.gitignore 対象）が CI に無くアプリビルドが失敗するため、ワークフローで**ダミー DropboxSecrets を生成**してからビルドする（静的解析に実キーは不要）。
- 結果: push ごとに回帰検知、設計資料が公開URL化、リリースノート自動化、秘密混入の自動ブロック。ワークフロー push にはトークンの `workflow` スコープが必要。iOS 26 シミュレータはランナー事情に依存するため iOS テストは非ブロッキング。
- 関連: `.github/workflows/ci.yml` / `pages.yml` / `release.yml`。

## ADR-9 Diagnostics で端末上ログ
- 状態: 採用
- 文脈: 実機で Mac/Console なしに不具合を追えない。
- 決定: 未捕捉例外・メモリ圧迫・各ログを `Caches/diagnostics.log` に残し、Developer Options で閲覧/共有。
- 結果: 実機の原因追跡が可能に。`fatalError`/SwiftData trap は対象外（標準クラッシュログ側）。
- 関連: コミット cfc8223 前後、`MosaicSupport/Diagnostics.swift`。
