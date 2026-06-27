<p align="center">
  <img src="docs/icon_256.png" width="120" alt="MosaicPhotos アイコン">
</p>

<h1 align="center">MosaicPhotos</h1>

<p align="center">
  端末内の写真と <b>Dropbox</b> の写真を 1 つの体験に統合する、プライバシー重視の iOS 写真ビューワー。すべて標準 Apple フレームワークで実装し、<b>外部 SDK は不使用</b>です。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-26%2B-blue" alt="iOS 26+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-orange" alt="SwiftUI">
  <img src="https://img.shields.io/badge/AI-on--device%20CLIP-purple" alt="on-device CLIP">
  <img src="https://img.shields.io/badge/tests-270%2B%20passing-brightgreen" alt="tests">
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
  <img src="docs/screenshots/home.png" width="230" alt="ホーム"><br>
  <b>ホーム</b><br>
  <sub>端末と Dropbox の写真を 1 か所に。さらに<b>撮影日時と場所</b>から旅行を自動でアルバム化（Time&nbsp;&amp;&nbsp;Place）。</sub>
</td>
<td align="center" width="50%">
  <img src="docs/screenshots/ai-compose.png" width="230" alt="AI アルバム作成"><br>
  <b>AI アルバム — 言葉で作る</b><br>
  <sub>「Landscape photos without people」のように任意の言語で入力するだけ。解釈も検索もオンデバイスのオープン語彙 CLIP で実行。</sub>
</td>
</tr>
<tr>
<td align="center" width="50%">
  <img src="docs/screenshots/ai-albums.png" width="230" alt="AI / フォルダアルバム"><br>
  <b>AI / フォルダアルバム</b><br>
  <sub>入力した条件はアルバムとして残り、取り込みが進むほど中身が埋まります。Dropbox のフォルダ名から推測したアルバムもここに。</sub>
</td>
<td align="center" width="50%">
  <img src="docs/screenshots/photo-info.png" width="230" alt="検出タグと写真情報"><br>
  <b>検出タグと情報</b><br>
  <sub>写真を開くと、オンデバイス CLIP のキーワードタグ・場所・日付・EXIF（カメラ/レンズ/露出）を表示。</sub>
</td>
</tr>
<tr>
<td align="center" colspan="2">
  <img src="docs/screenshots/cloud.png" width="230" alt="クラウド（Dropbox）"><br>
  <b>クラウド（Dropbox）</b><br>
  <sub>Dropbox の写真をピンチでサイズ変更できるグリッドで閲覧。差分同期で最新を保ち、ローカルにキャッシュ。</sub>
</td>
</tr>
</table>

<sub>スクリーンショットは iOS シミュレータで撮影したものです。</sub>

## 機能

- **All Photos** — 端末と Dropbox の写真を 1 つの時系列にまとめて表示します。
- **Time & Place** — 撮影日時と位置から旅行を自動検出してアルバム化（複数日・複数都市の旅行も1つに）。タイトルとカバーも自動。
- **AI アルバム & 意味検索** — **任意の言語**の自然文でアルバムを記述（例：「走っている子供」/ "a running child"）。クエリは**オンデバイス**で英語へ正規化（Apple Foundation Models、無ければフォールバック）し、**語彙リストに縛られないオープン語彙の CLIP 画像理解**（MobileCLIP・Core ML）＋構造化条件（日付・場所・人物）で検索します。**端末と Dropbox の両方**の写真が対象。
- **オンデバイス画像理解** — すべての写真（端末・Dropbox）にバックグラウンドで CLIP 画像埋め込みを付与し意味検索に使用。フルスクリーンの情報パネルには**検出キーワードタグ**（表示専用のゼロショットラベル）を表示。OCR なし・外部ビジョン API なし。バックグラウンドの取り込みは**速度段階**（穏やか〜高速）を選べ、電池・通信・スクロールの負荷を調整できます。
- **Photos** — PhotosKit で端末内ライブラリを閲覧。高速なサムネイルキャッシュとピンチでサイズ変更できるグリッド。
- **Cloud** — Dropbox の写真を閲覧。バックグラウンドの差分同期で一覧を最新に保ち、サムネイル・本体画像をローカルにキャッシュします。
- **Albums** — ユーザーが作成した端末アルバムを走査・キャッシュして表示します。
- **Places** — **オンデバイスの逆ジオコーディング**で写真を市区町村ごとにグルーピング。端末・Dropbox 双方の位置情報付き写真をまとめ、位置情報が増えるたびに自動で増えていきます。
- **Settings & Backup** — Dropbox 接続、キャッシュ上限の調整、端末写真の Dropbox へのバックアップ（人物 / アルバム / お気に入りのメタデータ付き）。

> すべてのソースで共通の表示モード：**dense**・**月**・**年**のグリッドレイアウト、ピンチでのサイズ変更、フルスクリーンのページング、EXIF 情報パネル（カメラ・F値・ISO・焦点距離）。

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
└── AutoAlbumCore     自動アルバム＋オンデバイス AI — 時間＋場所の旅行・フォルダ名・
                      オープン語彙 CLIP 意味検索・クエリ解釈/翻訳
```

- **ロジックと UI の分離** — `DropboxCore`（ロジック）と `DropboxKit`（UI）は別パッケージで、`DropboxCore` は SwiftUI を一切 import しません。
- **DI シーム** — 通信（`HTTPClient`）・時刻（`DateProvider`）・トークン（`AccessTokenProvider`）はプロトコル化されており、同期エンジン・バッチャ・認証・バックアップをネットワーク無しでテストできます。

### オンデバイス AI — 実装の概要

AI ロジックはすべて **`AutoAlbumCore`**（SwiftUI 非依存）にあり、オンデバイス実装をアプリ側が注入します。

- **埋め込み** — 各写真（端末・Dropbox 両方）を **MobileCLIP-S2**（Core ML・512 次元）で一度だけ正規化済み画像ベクトルにエンコードし、SwiftData（`PhotoEnrichment.clipVector`）へ保存。`PhotoTagger` が小さなバッチでバックグラウンド（`.background` QoS・速度はユーザー選択可）に埋めていきます。クラウド写真はキャッシュ済みサムネイルから埋め込みます。
- **検索** — クエリ（任意言語）を **Apple Foundation Models**（`QueryTranslator`）で英語に正規化し、CLIP の**テキスト**エンコーダで埋め込み、保存済み画像ベクトルとのコサイン類似で並べ替え（`SemanticRanker`）。これは**オープン語彙**で固定キーワードリストを持ちません。並行して構造化条件（日付/場所/人物）と字句一致（地名/人名）も求め、3 つの信号を **Reciprocal Rank Fusion**（`AIAlbumSearcher`）で統合します。
- **表示タグ** — フル画像の情報パネルのキーワードは、別の**表示専用**ゼロショット（`CLIPDisplayLabeler`）で生成：保存済み画像ベクトルを約 300 語の一般英語概念と比較します。これは検索を一切縛りません（検索は語彙ゼロのまま）。
- **シーム** — `PhotoPerceptionProvider`（画像→CLIP）/ `TextEmbedder`（テキスト→CLIP）/ `QueryTranslator` / `LabelProvider` は `AutoAlbumCore` のプロトコルで、アプリが `MobileCLIPRuntime`・`FoundationModels` で実装。`PhotoSourceKit` は AI を知らず、写真ごとの情報は `photoInsight` 環境クロージャ経由で受け取ります。

## ドキュメント

設計判断（ADR）・詳細実装（並行処理 / キャッシュ / データ構造）・**本アプリに依存しない汎用の AI 基礎知識**をまとめた、内部向けの**設計資料**（複数ページ HTML）があります。

- **[設計資料トップ → `docs/architecture-note/index.html`](docs/architecture-note/index.html)** — ブラウザで開いて閲覧（図は Mermaid）。

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
| オンデバイス AI | MobileCLIP の画像/テキスト埋め込み（Core ML）でオープン語彙検索 · Apple Foundation Models でクエリ解釈・翻訳 |
| 最小 OS | iOS 26 |
| パッケージ | Swift Package Manager（ローカル 10 パッケージ） |

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

意味検索と検出キーワードタグは **MobileCLIP**（Core ML）を使います。モデルは**コミットしていない**（サイズの都合）ため、ローカルで生成します：

```bash
bash scripts/build_mobileclip.sh   # MobileCLIP-S2 を変換 → MosaicPhotos/MobileCLIP/（約 250 MB）
```

モデルが無くてもアプリは完全に動作します（CLIP ベースの意味検索とキーワードタグだけが無効になり、日付・場所・人物の構造化条件は引き続き機能）。
