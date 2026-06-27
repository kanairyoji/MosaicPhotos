# 事例・バグ・大きめの課題対応 — マスター

> このファイルが**事例（バグ・性能課題・大きな対応）の正本（マスター）**です。HTML（`docs/architecture-note/case-studies/`）は、ここから必要なものを選んで詳述した派生物であり、全件を転記するとは限りません。
>
> **運用ルール**
> - 埋め込んだバグ、原因が非自明だった不具合、性能・メモリ・起動などの大きめの課題対応をしたら、必ずこのファイルに 1 項追記する（網羅）。
> - HTML へ詳細ページを作るかは別途指示で決める（取捨選択）。
> - フォーマット: `## タイトル` ＋ **症状 / 原因 / 対処 / 関連（コミット・ファイル） / 残課題**。
> - 「軽微な修正」は省いてよいが、「同じ罠に再びはまりそうなもの」は必ず残す。

## テンプレート

```
## タイトル
- 症状: 観測された事象。
- 原因: 真因（表面ではなく根本）。
- 対処: 何をどう直したか。
- 関連: コミット / 主なファイル。
- 残課題: あれば。
```

---

## 写真枚数に比例したメモリ枯渇（起動クラッシュ）
- 症状: 写真ゼロの端末では起動するが、写真が多い端末では起動前に落ちる。
- 原因: CLIP 埋め込み `clipVector`（512×fp32 ≈ 2KB/枚）を `PhotoEnrichment` に inline 格納。SwiftData は全件 fetch で行を丸ごと展開するため、`allEnrichedPhotosLite()` 等でも fetch 時点で 67k×2KB ≈ 138MB を確保し jetsam。複数経路の全件 fetch が起動直後に重なって悪化。
- 対処: 埋め込みを `PhotoEmbedding` 別テーブルへ分離（メタ fetch が blob に触れない）。Float16 で保存（2KB→1KB、読み出し時 fp32 復元）。検索はページング。大量 upsert は使い捨て `ModelContext` でチャンク save→解放。メモリ圧迫時は背景タグ付けを停止。スキーマは `AutoAlbumV10` で再構築。
- 関連: f84529c（本対応）、c08b287（前段: 検索のバッチ化）。`AutoAlbumStore.swift` / `PhotoEmbedding.swift` / `ClipMath.swift`。
- 残課題: 旧 V9 破棄により埋め込みは背景で再生成（精度は徐々に回復）。HTML 詳細あり。

## 起動が遅い・真っ白な待ち時間（高速化とローディング表示）
- 症状: 起動に時間がかかり、特にシミュレータで顕著。最初のフレームまで何も出ない。
- 原因: 各ストアが `init` で `ModelContainer` を同期構築し、`HomeView.init` がそれをまとめて行うため最初の描画をブロック。さらに起動直後に重い処理が同時実行されスパイク。
- 対処: `RootView` を新設し `HomeStores.build()` で非同期構築（合間に `Task.yield`）。1 秒超で「Now loading…」表示。バックグラウンド処理を段階起動（場所 +1.5s / AI +3s / バックアップ +5s）。
- 関連: 8bc97dd（非同期化・ローディング）、e8667e1・98369e1（スパイク対策・オフメイン化）。`RootView.swift` / `HomeView.swift`。
- 残課題: なし。HTML 詳細あり。

## 起動時 SwiftData クラッシュ＋キャッシュ二重オープン
- 症状: 実機でアプリ起動前に停止（解析ログにも残らない）。
- 原因: (A) `ModelContainer` 初期化がストア破損・スキーマ不整合で trap し、`fatalError` 相当で標準ハンドラを通らない。(B) Dropbox キャッシュのコンテナが二重に開かれていた。
- 対処: (A) `makeResilientContainer`（削除→再試行→インメモリ）で起動を止めない。(B) actor 経由に一本化。
- 関連: 7e53db3。`AutoAlbumStore.swift` / `DropboxCacheStore.swift` / `BackupEngine.swift`。
- 残課題: `fatalError`/SwiftData trap は端末診断ログに残らない（標準クラッシュログ側）。

## 実機で起動直後に落ちる（最小デプロイメントターゲット）
- 症状: 実機に入れると起動しない／インストールできない。
- 原因: `IPHONEOS_DEPLOYMENT_TARGET` が 26.5 になっており、端末 OS が下位だと不可。
- 対処: 26.0 へ引き下げ（Debug/Release 両方）。
- 関連: 736362b。`project.pbxproj`。
- 残課題: なし。

## サムネイルスクラバーが機能しない → UICollectionView 全面置換
- 症状: 右端スクラバーが動かない／大ジャンプで画面が止まる（特に Dropbox の大量グリッド）。
- 原因: (1) `enabled` トグルでスクロール subtree が再構築されジェスチャがキャンセル。(2) `onScrollGeometryChange` が `scrollTo` と競合。(3) 6.7 万件 `LazyVGrid` で `scrollTo(id)` が不安定。
- 対処: 段階的修正（R3 撤去・即時スクロール）後、根本解決として UICollectionView へ全面置換（contentOffset ベースのスクラバー、diffable、プリフェッチ）。
- 関連: 5b6c355 / 4320f41 / ef168d5 / 9897653。`PhotoCollectionView.swift` / `GridScrubberView.swift`。
- 残課題: なし。ADR-4 参照。

## サムネイルが横長・1 列になるレイアウト崩れ
- 症状: グリッドの各セルが極端に横長で 1 列しか入らない。
- 原因: `CompositionalLayout` の `repeatingSubitem:count:` が item の `fractionalWidth(1)` を尊重して 1 列化。
- 対処: `subitems:[item]` に変更し、item 幅を `fractionalWidth(1/cols)` ＋ `contentInsets` で指定。
- 関連: 8931bb3。`PhotoCollectionView.swift`。
- 残課題: なし。

## アルバムを開いて戻ると無関係な写真になる
- 症状: 子アルバム → Dropbox サムネで過去写真を見る → 戻ると別アルバムの中身が表示される。
- 原因: 複数の `.fullScreenCover(item:)` / `.sheet(item:)` を併用し、提示competitionで対象が入れ替わる。
- 対処: 遷移先を単一の `HomeDestination` enum＋1 つの `.fullScreenCover` に統合（`.sheet` も統合）。
- 関連: `HomeView.swift`（コミット履歴参照）。ADR-5。
- 残課題: なし。
