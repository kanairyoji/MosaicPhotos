# MosaicPhotos 設計資料（Architecture Note）

MosaicPhotos の構造・設計判断・使用技術をまとめた内部向け HTML ドキュメント。

## 開き方

ビルド不要。`index.html` をブラウザで開くだけ（ダブルクリック可）。

```bash
open docs/architecture-note/index.html
```

- 依存ゼロの静的 HTML。共通スタイルは `assets/styles.css`、サイドバー/前後ナビ/コードリンク解決は `assets/nav.js`。
- 図は Mermaid（CDN）。**オフラインだと図はテキストのまま表示**される（CDN 不達のフォールバック）。図も見たい場合はネット接続のある環境で開く。

## 構成

- `index.html` — 概要・歩き方
- `architecture/` — 全体像・パッケージ・並行性・データフロー
- `features/` — 写真ソース統一 / グリッド / Dropbox / オンデバイス AI / バックアップ / 場所 / キャッシュ / 診断
- `tech/` — 技術プライマー（Observation / SwiftData / PhotosKit / CLIP / Core ML・FM / OAuth PKCE / SPM）
- `design-decisions/` — 設計判断の記録（ADR）
- `case-studies/` — メモリ枯渇の解消 / 起動の高速化
- `appendix/` — 用語集 / 規約とテスト方針

## メンテナンス

- 目次（サイドバー）の定義は `assets/nav.js` の `NAV` 配列が唯一の出典。ページを増減したらここを更新する。
- 各ページは `<head>` で `window.DOCROOT`（このページから `docs/architecture-note/` への相対パス）と `window.PAGE`（`NAV` の id）を宣言する。
- コードへのリンクは `<a class="srclink" data-path="Packages/...">` と書くと `nav.js` がリポジトリルート基準で解決する。
