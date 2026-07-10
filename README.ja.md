<p align="center">
  <img src="docs/icon_256.png" width="120" alt="MosaicPhotos アイコン">
</p>

<h1 align="center">MosaicPhotos</h1>

<p align="center">
  端末内の写真と <b>Dropbox</b> の写真を 1 つの体験に統合する、プライバシー重視の iOS 写真ビューワー。すべて標準 Apple フレームワークで実装し、<b>外部 SDK は不使用</b>です。
</p>

<p align="center">
  <a href="https://github.com/kanairyoji/MosaicPhotos/actions/workflows/ci.yml"><img src="https://github.com/kanairyoji/MosaicPhotos/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/kanairyoji/MosaicPhotos/actions/workflows/codeql.yml"><img src="https://github.com/kanairyoji/MosaicPhotos/actions/workflows/codeql.yml/badge.svg" alt="CodeQL"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-AGPL%20v3-blue.svg" alt="License: AGPL v3"></a>
  <img src="https://img.shields.io/badge/iOS-26%2B-blue" alt="iOS 26+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-orange" alt="SwiftUI">
  <img src="https://img.shields.io/badge/AI-on--device%20CLIP-purple" alt="on-device CLIP">
  <img src="https://img.shields.io/badge/tests-270%2B%20passing-brightgreen" alt="tests">
  <a href="https://kanairyoji.github.io/MosaicPhotos/architecture-note/"><img src="https://img.shields.io/badge/docs-Architecture%20Note-brightgreen" alt="Architecture Note"></a>
</p>

<p align="center">
  <a href="README.md">English</a> | <b>日本語</b>
</p>

---

## 概要

**MosaicPhotos** は、iPhone 内の写真と Dropbox 上の写真を並べて閲覧できるアプリです。両者を統合した時系列ビュー、端末のアルバム、そして写真を市区町村ごとにまとめる自動の **Places（場所）** ビューを、すっきりとした SwiftUI で提供します。Dropbox は OAuth 2.0 + PKCE で HTTP API に直接接続しており、Dropbox SDK もアナリティクスも使用していません。

## スクリーンショット

<table>
<tr>
<td align="center" width="50%">
  <img src="docs/screenshots/home.jpg" width="230" alt="ホーム"><br>
  <b>ホーム</b><br>
  <sub>端末と Dropbox の写真を 1 か所に。さらに<b>撮影日時と場所</b>から旅行を自動でアルバム化（Time&nbsp;&amp;&nbsp;Place）し、<b>ピープル</b>を端末内でクラスタリング。</sub>
</td>
<td align="center" width="50%">
  <img src="docs/screenshots/ai-compose.jpg" width="230" alt="AI アルバム作成"><br>
  <b>AI アルバム — 言葉で作る</b><br>
  <sub>「ここ2年以内の子供の写真」「人が写っていない風景」のように任意の言語で入力するだけ。オンデバイス LLM が一度だけ解釈し、シーンタグ＋CLIP＋LLM 審査の多層でマッチング。すべて端末内で完結。</sub>
</td>
</tr>
<tr>
<td align="center" width="50%">
  <img src="docs/screenshots/ai-albums.jpg" width="230" alt="ピープル / AI アルバム"><br>
  <b>ピープル / AI アルバム</b><br>
  <sub>顔は完全に端末内で検出・クラスタリング。タップで人物の写真一覧、長押しで名前変更や代表写真の変更。その下には、入力した条件が AI アルバムとして残り、取り込みが進むほど中身が埋まります。</sub>
</td>
<td align="center" width="50%">
  <img src="docs/screenshots/photo-info.jpg" width="230" alt="写真情報"><br>
  <b>写真情報と EXIF</b><br>
  <sub>写真を開くと、場所・日付・EXIF（カメラ/レンズ/露出）と地図を表示。端末内で生成されたシーンタグと AI 説明文も。</sub>
</td>
</tr>
<tr>
<td align="center" width="50%">
  <img src="docs/screenshots/cloud.jpg" width="230" alt="グリッド閲覧"><br>
  <b>クラウド（Dropbox）</b><br>
  <sub>Dropbox の写真をピンチでサイズ変更できるグリッドで閲覧。差分同期で最新を保ち、ローカルにキャッシュ。</sub>
</td>
<td align="center" width="50%">
  <img src="docs/screenshots/grid-months.jpg" width="230" alt="月グループの密表示"><br>
  <b>月グループの密表示</b><br>
  <sub>写真の少ない月をまとめて範囲ヘッダー（例「2021-02 – 2021-04」）の下に密に表示。設定 → Photo Grid で調整可。</sub>
</td>
</tr>
</table>

<sub>スクリーンショットは iOS シミュレータで撮影したものです。</sub>

## 機能

- **All Photos** — 端末と Dropbox の写真を 1 つの時系列にまとめて表示します。
- **People（ピープル）** — 顔を**完全に端末内**で検出・クラスタリング：Vision の顔検出＋同梱の顔モデル（facenet InceptionResnetV1 / VGGFace2・MIT・512 次元の identity 埋め込み）で顔を人物ごとにまとめます。iOS には公開の「ピープル」API が無いため、通信なしでアプリ独自のクラスタを構築しています。ホームに円形アバターのカルーセルを表示：タップで人物の写真一覧、長押しで名前変更や代表写真の変更。**端末写真のみ**が対象で、顔モデルが未同梱ならセクションは非表示。このクラスタは AI アルバムの人物条件（例「〜と一緒の写真」）の接地にも使われます。
- **Time & Place** — 撮影日時と位置から旅行を自動検出してアルバム化（複数日・複数都市の旅行も1つに）。タイトルとカバーも自動。
- **AI アルバム & 意味検索** — **任意の言語**の自然文でアルバムを記述（例：「走っている子供」、「京都か奈良の家族のお気に入り、スクショ除く」）。作成は**2 段階**：まず決定的な**プレビュー**が 1〜2 秒で表示され（レキシコン＋日付＋タグ照合・LLM なし）、その後**次のバックグラウンド枠**（通常は夜間）で**本番化**されます。リクエストはオンデバイス LLM（Apple Foundation Models）が**作成時に一度だけ**解釈して保存し（日付・場所・頻出視覚語は決定的パーサで接地）、**閾値レスの多層パイプライン**で検索します：校正済み**シーンタグ**（OS 内蔵 Vision・約1,300クラス）＋ **CLIP 対比**（肯定 vs 否定概念）＋字句一致を融合し、最後に**オンデバイス LLM が各写真の証拠**（タグ・顔数・キャプション）**を読んで審査**（迷いは多数決）。「人が写っていない」などの除外は、実測の**顔検出数**とタグ・CLIP の証拠を組み合わせて守ります。「ここ2年」などの相対日付も決定的に解釈。**端末と Dropbox の両方**の写真が対象。
- **オンデバイス画像理解** — 写真はバックグラウンドで 3 段階に索引化されます：**シーンタグ**（Vision・精度校正済み）、**CLIP 埋め込み**（ANE でバッチ推論）、任意の **VLM キャプション**（同梱 SmolVLM-256M・写真ごとに英語1文・数晩がかり）。フルスクリーンの情報パネルには常にタグ欄（生成済みなら AI 説明文も）を表示。既定では重い処理（タグ・埋め込み・キャプション・顔スキャン・アルバム生成）は**充電中＋Wi-Fi＋アプリ非使用時のみ**（ロック中も BGProcessingTask で）実行され、邪魔になりません。タイミングは 5 段階でユーザー選択可（後述）。OCR なし・外部ビジョン API なし・通信なし。
- **Photos** — PhotosKit で端末内ライブラリを閲覧。高速なサムネイルキャッシュとピンチでサイズ変更できるグリッド。
- **Cloud** — Dropbox の写真を閲覧。バックグラウンドの差分同期で一覧を最新に保ち、サムネイル・本体画像をローカルにキャッシュします。
- **Albums** — ユーザーが作成した端末アルバムを走査・キャッシュして表示します。
- **Places** — **オンデバイスの逆ジオコーディング**で写真を市区町村ごとにグルーピング。端末・Dropbox 双方の位置情報付き写真をまとめ、位置情報が増えるたびに自動で増えていきます。
- **Settings & Backup** — Dropbox 接続、キャッシュ上限の調整、端末写真の Dropbox へのバックアップ（人物 / アルバム / お気に入りのメタデータ付き）。
- **バックグラウンド・電池・通信の制御** — 2 つの独立した制御で電池とモバイル通信を抑えます。
  - **処理のタイミング（Processing Timing）**（設定 → Albums & Search → Auto Albums）は、**重い AI 処理**（シーンタグ・CLIP 埋め込み・キャプション・顔スキャン・アルバム生成）を**いつ動かすか**を 5 段階で決めます：*一時停止（手動のみ）* ／ *おまかせ（アプリ非使用時）*（**既定**：充電＋Wi-Fi＋アプリ非使用時。ロック中も BGProcessingTask で）／ *アプリ使用中も（充電時）*（操作の合間＝タッチから 20 秒アイドルで開始・タッチで即停止）／ *バッテリーでも（Wi-Fi）*（残量 20% 以上）／ *制限なし（モバイル回線も）*。どの段階でも低電力モードとメモリ圧迫時は必ず停止します。
  - **Background & Battery**（設定 → General）は、残りの継続/定期のバックグラウンド処理（Dropbox 同期・バックアップ・スキャン）に対するアプリ横断のポリシーで、**電源**（充電中のみ／常時／OFF・既定は*充電中のみ*・低電力モード OFF）と**回線**（セルラー可／Wi-Fi のみ／Wi-Fi・低データ時は除く／OFF・既定は*Wi-Fi のみ*）を設定します。閲覧・オープン中の写真は常に取得し、自動の背景通信だけを制限。CLIP 取り込みはスマートで、セルラー時はローカル写真の取り込みを続け、クラウド写真は Wi-Fi まで保留します。最上部の**アクティビティバー**（任意表示）で電源/回線の状態と背景/Dropbox の稼働をライブ可視化。
- **大規模ライブラリ対応** — 数万枚規模を想定し、メタデータと画像ベクトルはページングと省メモリ保存（Float16）。メモリ圧迫時は診断を記録し、**画像キャッシュを能動的に解放**（warning で縮小・critical で全消去）してクラッシュを避け安定動作します。

> すべてのソースで共通の表示モード：**dense**・**月**・**年**のグリッドレイアウト、ピンチでのサイズ変更、フルスクリーンのページング、EXIF 情報パネル（カメラ・F値・ISO・焦点距離）。**月**レイアウトは写真の少ない月をまとめて密に表示します（連続する少枚数の月を貪欲に行へ詰め、範囲ヘッダー「2024-01 – 2024-03」を付ける）。密度（何行ごとに見出しを出すか）は **設定 → General → Photo Grid** で調整できます。

## アーキテクチャ

アプリは責務ごとのローカル Swift Package Manager モジュールに分割されています。ロジック層は UI 非依存のため、macOS の `swift test` で単体テストできます。

```
MosaicPhotos（アプリ）
├── MosaicSupport     横断ユーティリティ（ロギング）。依存なし
├── PhotoSourceKit    写真ソース共通インターフェイス（PhotoStore / PhotoItem）＋グリッド・ページング
├── ImageCacheKit     画像キャッシュのプリミティブ（メモリ＋ディスク I/O）。SwiftUI 非依存
├── LocalPhotoCore    端末写真のロジック（PHAsset ストア・アルバム・サムネイルキャッシュ）
├── LocalPhotoKit     端末写真の UI 層（LocalPhotoCore に依存）
├── DropboxCore       Dropbox ロジック — OAuth/PKCE・HTTP API・同期エンジン・キャッシュ（SwiftUI 非依存）
├── DropboxKit        Dropbox UI 層（DropboxCore に依存）
├── BackupKit         端末 → Dropbox バックアップエンジン
├── PhotosFeatureKit  ローカル＋Dropbox 統合（MergedPhotoStore）と場所グルーピング
├── AutoAlbumCore     自動アルバム＋オンデバイス AI ロジック（SwiftUI 非依存）— 時間＋場所の旅行・
│                     フォルダ名アルバム・合成可能なクエリモデル（OR/NOT）・検索/融合
└── MobileCLIPKit     CLIP/翻訳ランタイム＋AutoAlbumCore の seam 実装
                      （MobileCLIPRuntime・知覚/言語アダプタ・表示ラベラ）
```

- **ロジックと UI の分離** — `DropboxCore`（ロジック）と `DropboxKit`（UI）は別パッケージで、`DropboxCore` は SwiftUI を一切 import しません。
- **DI シーム** — 通信（`HTTPClient`）・時刻（`DateProvider`）・トークン（`AccessTokenProvider`）はプロトコル化されており、同期エンジン・バッチャ・認証・バックアップをネットワーク無しでテストできます。

### オンデバイス AI — 実装の概要

AI ロジックはすべて **`AutoAlbumCore`**（SwiftUI 非依存）にあり、オンデバイス実装をアプリ側が注入します。

- **埋め込み** — 各写真（端末・Dropbox 両方）を **OpenCLIP ViT-B-32（DataComp）**（Core ML・512 次元）で一度だけ正規化済み画像ベクトルにエンコード。モデルは**オンデバイス認識率ベンチマーク**（`scripts/eval_recognition.sh`）で選定：ImageNet-1k ゼロショット **約75% top-1**、自然文クエリ **10/10**。認識率と端末負荷（軽量な patch32・画像エンコーダ ~60MB）のバランスで採用。ベクトルは **SwiftData の別テーブル（`PhotoEmbedding`）に Float16 で保存**し、メタデータ fetch が blob に触れないようにしています（写真枚数比例の起動クラッシュを解消）。`PhotoTagger` が小さなバッチでバックグラウンド（`.background` QoS・速度はユーザー選択可）に埋めていきます。クラウド写真はキャッシュ済みサムネイルから埋め込みます。
- **シーンタグとキャプション** — CLIP に加え、全写真に OS 内蔵 Vision 分類器の**シーンタグ**（約1,300クラス・`hasMinimumRecall(forPrecision:)` による精度校正済み＝手調整の閾値なし）を付与。任意同梱の **SmolVLM-256M**（`scripts/build_smolvlm.sh`・Apache-2.0）があれば英語1文の**キャプション**も生成します。3 つの索引はバックグラウンドのパイプライン（タグ→埋め込み→キャプション）が、既定では**充電中＋Wi-Fi＋アプリ非使用時のみ**（ロック中も BGProcessingTask で）埋めていきます。タイミングは 5 段階でユーザー選択可（「バックグラウンド・電池・通信の制御」参照）。
- **2 段階のアルバム作成** — AI アルバムを作ると、まず**決定的プレビュー**が即座に表示され（レキシコン＋日付＋タグ照合・LLM なし・1〜2 秒）、その後**次のバックグラウンド枠**（通常は夜間）で**本番化**されます（LLM 解釈＋証拠ゲート＋LLM 審査）。写真の索引が進むほど結果は改善します。
- **解釈** — リクエストはアルバム**作成時に一度だけ** LLM（Apple Foundation Models）が解釈し、版付きで永続化。小型 LLM の構造化出力は乱れるため、防御的サニタイズと決定的レイヤー（日付は `RelativeDateParser` のみ・場所/人物はカタログ/原文接地・`JapaneseVisualLexicon` が頻出視覚語と人物否定を抽出）で必ず接地します。
- **検索** — ハード条件（`QueryEvaluator`）で絞った後、**タグ一致**（離散・閾値レス）＋**CLIP 対比**（肯定 vs 除外概念の相対比較のみ）＋字句一致を **Reciprocal Rank Fusion** で融合。除外つきアルバムは**証拠ゲート**（タグ・顔実測・キャプションのいずれか必須）を通り、最後に **LLM 審査**（`AlbumVerifier`）が各候補の証拠行を読んで採否を判定（迷いは多数決）。再評価は増分＝新しく索引された写真だけを採点してスコアプールへ統合します。
- **表示タグ** — フル画像の情報パネルのキーワードは、別の**表示専用**ゼロショット（`CLIPDisplayLabeler`）で生成：保存済み画像ベクトルを約 300 語の一般英語概念と比較します。これは検索を一切縛りません（検索は語彙ゼロのまま）。
- **シーム** — `PhotoPerceptionProvider`（画像→CLIP）/ `TextEmbedder`（テキスト→CLIP）/ `QueryTranslator` / `LabelProvider` は `AutoAlbumCore` のプロトコルで、**`MobileCLIPKit`** が `MobileCLIPRuntime`・`FoundationModels` で実装し、アプリの合成ルートが注入します。`PhotoSourceKit` は AI を知らず、写真ごとの情報は `photoInsight` 環境クロージャ経由で受け取ります。

## ドキュメント

設計判断（ADR）・詳細実装（並行処理 / キャッシュ / データ構造）・**本アプリに依存しない汎用の AI 基礎知識**をまとめた、内部向けの**設計資料**（複数ページ HTML）があります。

- **[設計資料トップ → kanairyoji.github.io/MosaicPhotos/architecture-note](https://kanairyoji.github.io/MosaicPhotos/architecture-note/)** — GitHub Pages で公開（図は Mermaid）。ソース: [`docs/architecture-note/`](docs/architecture-note/)。エンドユーザー向け **[ヘルプ](https://kanairyoji.github.io/MosaicPhotos/help/)** も公開（ソース: [`docs/help/`](docs/help/)）。

> 記録のマスターは `docs/architecture-note/records/*.md`（Markdown）で、HTML はそこから取捨選択した派生物です。

## 技術スタック

| 項目 | 技術 |
|---|---|
| 言語 / UI | Swift · SwiftUI |
| 状態管理 | Swift Observation（`@Observable`） |
| 端末写真 | PhotosKit（`PHPhotoLibrary`・`PHImageManager`） |
| Dropbox 認証 | `AuthenticationServices`（`ASWebAuthenticationSession`・OAuth 2.0 + PKCE） |
| トークン保存 | Keychain Services |
| Dropbox API | `URLSession` async/await（SDK 不使用） |
| キャッシュ | SwiftData（メタデータ）＋ LRU 破棄付き独自バイナリキャッシュ |
| オンデバイス AI | Vision 画像分類（OS 内蔵・約1,300クラス）· OpenCLIP ViT-B-32（DataComp/MIT）埋め込み · SmolVLM-256M キャプション（Apache-2.0・任意）· ピープル用の facenet InceptionResnetV1 顔埋め込み（VGGFace2/MIT・任意）— すべて Core ML · Apple Foundation Models で解釈・翻訳・候補審査 |
| 最小 OS | iOS 26 |
| パッケージ | Swift Package Manager（ローカル 11 パッケージ） |

## プライバシーとセキュリティ

- **外部 SDK 不使用** — すべて標準 Apple フレームワーク。
- Dropbox は **OAuth 2.0 + PKCE**。アクセス / リフレッシュトークンは **Keychain** に保存し、平文ファイルには保存しません。
- **オンデバイス処理** — 逆ジオコーディングと EXIF 解析は端末内で実行。
- アナリティクス・トラッキングなし。

## ビルドとテスト

```bash
# ビルド（iOS シミュレータ）
xcodebuild -project MosaicPhotos.xcodeproj -scheme MosaicPhotos -sdk iphonesimulator build

# 全テスト（パッケージ＋アプリターゲット）— 270+ 件
scripts/test.sh all

# サブセット
scripts/test.sh fast   # macOS swift test（純ロジック）
scripts/test.sh ios    # iOS シミュレータのパッケージテスト
scripts/test.sh app    # アプリターゲットの単体テスト
```

### オンデバイス AI モデル（任意）

意味検索と検出キーワードタグは **OpenCLIP** モデル（Core ML）を使います。モデルは**コミットしていない**（サイズの都合）ため、ローカルで生成します：

```bash
bash scripts/build_mobileclip.sh   # OpenCLIP ViT-B-32（DataComp・MIT）を変換 → MosaicPhotos/MobileCLIP/
```

モデルが無くてもアプリは完全に動作します（CLIP ベースの意味検索とキーワードタグだけが無効になり、日付・場所・人物の構造化条件は引き続き機能）。

## ライセンス

ソースコードは **GNU Affero General Public License v3.0 or later（AGPL-3.0-or-later）** で配布します（[LICENSE](LICENSE) 参照）。

**デュアル配布:** AGPL に加えて、著作権者（Ryoji KANAI）はコンパイル済みアプリを Apple App Store で Apple 標準条件のもと配布します（[NOTICE](NOTICE) 参照）。コントリビュートは DCO ＋ 再ライセンス許諾のもとで受け付けます（[CONTRIBUTING.md](CONTRIBUTING.md)）。

第三者の資産はアプリ内 **設定 → ライセンス**（および `MosaicPhotos/Settings/Licenses.swift`）に一覧表示します：同梱 CLIP モデルは **OpenCLIP ViT-B-32（DataComp・MIT）**、CLIP の BPE 語彙／トークナイザ（MIT）、ビルドツール（coremltools・PyTorch・open_clip・Pillow・NumPy）、Mermaid（ドキュメント）。Apple SDK と SF Symbols は Apple の条件に従います。
