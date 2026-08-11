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
- `design-decisions/` — 設計判断・事例ハイライト（重要トップ10。全件は `records/` の MD）
- `case-studies/` — メモリ枯渇と圧縮 / 起動の高速化
- `appendix/` — 用語集 / 規約とテスト方針

## 記録のマスターは Markdown（重要）

設計判断・事例（バグ・大きめの課題対応）の**正本は `records/` 配下の Markdown**。

- `records/decisions.md` — 設計判断（ADR）のマスター
- `records/case-studies.md` — 事例・バグ・大きめの課題対応のマスター

HTML（`design-decisions/adr.html` / `case-studies/*.html`）は、この MD から**必要なものを選んで**記載した派生物。全件を転記するとは限らない。

**運用**: 設計判断・埋め込んだバグ・大きな課題対応をしたら、まず MD に 1 項追記して網羅する。HTML 化（取捨選択）は別途指示で行う。詳細は各 MD 冒頭の「運用ルール」とリポジトリ直下 `CLAUDE.md` の該当節を参照。

## メンテナンス

- 目次（サイドバー）の定義は `assets/nav.js` の `NAV` 配列が唯一の出典。ページを増減したらここを更新する。
- 各ページは `<head>` で `window.DOCROOT`（このページから `docs/architecture-note/` への相対パス）と `window.PAGE`（`NAV` の id）を宣言する。
- コードへのリンクは `<a class="srclink" data-path="Packages/...">` と書くと `nav.js` がリポジトリルート基準で解決する。
