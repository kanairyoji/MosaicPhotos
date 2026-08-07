# App Store リリース手順

各バージョンのリリースノート原稿は `docs/release-notes/<version>.md`（日本語・英語の 2 本）。

## 言語の方針

**日本の App Store は日本語、それ以外は英語**にする。App Store のメタデータは
**国別ではなく言語別（localization）**に持つので、次の 2 つだけを用意すれば要件を満たす。

| ロケール | 用途 |
|---|---|
| `ja` | 日本の App Store |
| `en-US` | 英語圏の App Store |

**確認済み（1.14 時点）**:

- このアプリの **primary locale は `ja`**。App Store は「そのロケールの localization が無ければ
  primary locale の文言を出す」ので、**`ja` を日本語にするなら `en-US` が必ず要る**。
  でないと英語圏のストアに日本語が出る。逆に `en-US` が無い状態で `ja` を英語のままにすれば
  全世界に英語が出る（1.13 まではこの運用だった）。
- **英語ロケールでは「MosaicPhotos」というアプリ名が使えない**（他社アプリが取得済み。
  `409 STATE_ERROR.DUPLICATE_NAME.DIFFERENT_ACCOUNT`）。そのため `en-US` の App Info には
  別名 **`MosaicPhotos – On-Device AI`** を登録している。ロケールを増やすときは同じ壁に当たり得る。
- 新バージョンを作った直後は前バージョンの文言・スクリーンショットが引き継がれる。
  **whatsNew だけは空**で引き継がれるので、**全ロケール必ず入れる**。

## 配信地域（2026-08-07 から日本のみ）

- **日本限定**で配信する（availableInNewTerritories=false・JPN のみ available）。
  アプリ単位の設定なので全バージョンに適用される。
- ⚠️ **API からは変更できない**（v2 appAvailabilities は CREATE のみ許可なのに、既存設定が
  あると 409「already exists」で拒否・territoryAvailabilities は読み取り専用・v1 は廃止済み）。
  変更は App Store Connect の Web UI（価格および配信状況 → 配信可能状況）で行う。
- 補足: EU 圏は DSA のトレーダー情報未提出により以前から CANNOT_SELL だった（日本限定化で対応不要に）。

## 手順

### 0. 事前確認

- `MARKETING_VERSION` がリリースするバージョンになっているか（アプリターゲットの Debug/Release 両方）。
- `CURRENT_PROJECT_VERSION`（ビルド番号）は**同一バージョン内で一意**である必要がある。
  同じバージョンで再アップロードするときは必ず上げる。
- `scripts/test.sh all` とアプリターゲットのテストが通っているか。
- 設計資料（`docs/architecture-note/`）とヘルプ（`docs/help/`）が現状のコードに追随しているか。

### 1. タグを打って GitHub Release を作る

```bash
git tag v<version> && git push origin v<version>
```

`.github/workflows/release.yml` がタグ push を拾って GitHub Release を自動生成する
（リリースノートはコミットから自動生成。App Store 用の文面とは別物）。

### 2. ビルドをアップロードする

Xcode の Archive → Distribute App、または Transporter を使う。
**バイナリのアップロードは MCP では行わない**（App Store Connect API はビルドの
アップロード自体を提供していないため）。

アップロード後、App Store Connect 側の処理が終わってビルドが選択可能になるまで待つ。

### 3. バージョンとリリースノートを投入する（asc-mcp）

`asc-mcp` は `~/.claude.json` のルートに登録済み。**Claude Code を再起動しないとツールが
読み込まれない**ので、再起動してから作業する。書き込み系（バージョン作成・文言更新・
ビルド紐付け・提出）は**一通り使える**ことを 1.14 で確認した。

固定値: app_id = `6783814922` / bundleId = `com.kanai.MosaicPhotos`

1. `company_current` で company が `MosaicPhotos` であることを確認。
2. `app_versions_list` で既存バージョンを見る。無ければ `app_versions_create`
   （platform=`IOS`, version_string=`1.14`, copyright=`c Ryoji KANAI, 2026`,
   release_type=`AFTER_APPROVAL`）。**返ってきた version_id を以降で使う。**
3. `apps_list_localizations` で引き継がれたロケールを確認し、**ロケールごとに**
   `apps_update_metadata`（`whats_new` に `<version>.md` の各ブロック）。
   - 新規ロケールは先に `app_info_create_localization`（name/subtitle/privacy URL）を作る。
     これを作ると**バージョン側の localization も自動生成される**ので、
     `apps_create_localization` は 409 になる。`apps_update_metadata` で入れること。
4. ビルドが processing 完了したら `app_versions_attach_build`。
5. `app_versions_submit_for_review`（ないし `review_submissions_*`）で提出。

### 提出でつまずいたとき

- `STATE_ERROR.ENTITY_STATE_INVALID`（「appStoreVersions ... is not in valid state」）は
  **メタデータの不足**。API は総括エラーしか返さず**どの項目が欠けているか分からない**ので、
  Web UI で 1.14 のページを開いて「審査に追加」を押し、赤字の指摘を読むのが速い。
  1.14 では **en-US の iPad スクリーンショット欠落**が原因だった。
  アプリは `TARGETED_DEVICE_FAMILY = "1,2"`（iPhone+iPad）なので、
  **ロケールごとに iPhone と iPad の両方**が要る。
- 提出を取り消すとバージョンは **`DEVELOPER_REJECTED`** になる。
  **新しいバージョンを作る必要はない**（同じ versionString は二重に作れない）。
  ビルドもメタデータも残っているので `app_versions_submit_for_review` でそのまま再提出できる。
- 提出フローが途中で失敗すると**空の reviewSubmission が残る**ことがある。
  Apple が「cancellable な状態ではない」と返して MCP からは消せないが、中身が空なら実害はない。

### MCP で出来ないこと（Web UI か Xcode で行う）

- **バイナリのアップロード**: Xcode の Archive → Distribute App、または Transporter。
- **スクリーンショットのアップロード**: `screenshots_upload` / `screenshots_upload_batch` は
  Apple の予約レスポンス検証で失敗し、**`AWAITING_UPLOAD` の空予約だけが残る**（1.14 で確認）。
  失敗したら `screenshots_list` → `screenshots_delete` で空予約を消し、Web UI から入れる。
  なお `screenshots_create_set` も検証エラーを返すが**セット自体は作られている**ことがある
  （`screenshots_list_sets` で必ず確認する）。
  既存ロケールの画像を別ロケールへ複製したいときは、`screenshots_list` が返す
  `imageAsset.templateUrl` の `{w}x{h}bb.{f}` を実寸に差し替えて原寸 PNG を取得できる
  （例: `.../home.png/1242x2688bb.png`）。ローカルに原本が無くてもこれで揃う。

### 4. 提出後の確認

- 両ロケールの「このバージョンの新機能」が**意図どおり入れ替わっている**か（前バージョンの
  文言が残っていないか）。
- 日本の App Store のプレビューで日本語、それ以外で英語になっているか。
- スクリーンショットやアプリ説明を変えた場合は、そちらもロケールごとに更新したか。

## 参考

- リリースノートの原稿: `docs/release-notes/<version>.md`
- GitHub Release の自動生成: `.github/workflows/release.yml`
