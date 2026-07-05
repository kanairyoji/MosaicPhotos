# バックグラウンド処理と重さの現状まとめ

> パフォーマンスチューニング（2026-07 実機計測シリーズ）後の現状。実測値は iPhone 実機
> （ローカル 17,695 枚・Dropbox 67,639 枚・計 85,334 枚）の diagnostics ログに基づく。
> 実行条件の中枢は `MosaicSupport.BackgroundYield`（重い処理）と `PowerStateMonitor`（電源ポリシー）。

## 実行条件の3層

| 層 | 条件 | 対象 |
|---|---|---|
| **重い処理**（heavyWorkAllowed） | 電源接続 AND 低電力OFF AND **最後の操作から60秒以上アイドル** AND UI非ビジー。CLIP/顔はさらにアルバム生成と相互排他 | アルバム生成（定期）・CLIP 埋め込み・顔スキャン |
| **中程度**（backgroundAllowed＝設定の電源ポリシー） | 既定「充電中かつ低電力OFF」（設定で変更可）＋回線ポリシー | バックアップ・場所の定期再スキャン・Dropbox 同期 |
| **ユーザー連動**（ゲートなし・意図的） | 閲覧中の体感を支える処理はいつでも動く | サムネ取得/先読み・フル画像取得・メタ先読み |

「操作」の定義: 画面遷移・設定シート・スクラブ・写真閲覧・スクロール起因の取得
（`BackgroundActivityMonitor.noteUserInteraction`）。**起動直後は非アイドル扱い**（起動時刻=最終操作）。

## バックグラウンド処理一覧

| 処理 | いつ動く | 実行条件 | 重さ（実測） | スレッド |
|---|---|---|---|---|
| **自動アルバム生成**（旅行/フォルダ） | 起動時 loadOrGenerate（キャッシュあれば即ロードのみ）／10秒ティックで差分検知時／手動「今すぐ生成」 | 定期＝heavyWorkAllowed＋backgroundEnabled 設定＋差分あり。初回と手動は例外（即実行） | 全体 22〜26s（85k件）。SwiftData fetch/prune/upsert＋純計算。メモリ +100〜150MB | **オフメイン**（E1: Store detached 生成＋A: 計算 detached） |
| **CLIP 埋め込み**（意味検索の索引） | loadOrGenerate 完了時／AIアルバム作成時にスケジュール。以後トリクル実行 | heavyShouldPause を**1枚ごと**に確認（電源+アイドル+生成と相互排他）。クラウド分は回線ポリシーも | ~150–300ms/枚（ANE・モデルロード直後は ~1s）。既定プリセット Gentle=8枚/2.5s休止。残 72k枚 → 完了は日単位のトリクル。**モデルロード自体 16–35s・メモリ +150MB 級（遅延ロード・背景）** | オフメイン（推論 detached・保存 Store actor） |
| **顔スキャン**（ピープル） | 起動タスクで候補列挙→スキャン開始（未スキャン分のみ） | heavyShouldPause を 1枚ごと確認（同上）。シミュレータは既定スキップ | 0.4〜5.6s/8枚バッチ（800px ロード＋Vision＋facenet×顔数）。残 13k枚 | オフメイン（検出 SE-0338 実行・保存 FaceStore=E1 で detached 生成） |
| **AI アルバム再評価** | 埋め込みバッチ完了ごと＋loadOrGenerate 時 | 埋め込みに追従（＝実質 heavy ゲート内） | 意味スコアリング ~12.7k 件×512 次元＋ベクトルページ読み。~1s 級 | オフメイン（スコアリング/カタログ構築を Task.detached 化済み） |
| **場所スキャン** | 起動 1.5s 後に loadOrScan（キャッシュあれば即）／10秒ティックで差分時 | 定期＝backgroundAllowed＋回線ポリシー | 数秒（85k 座標グルーピング・オフライン地名DB）。起動時スパイク +100MB 級を観測 | オフメイン（Task.detached） |
| **端末アルバムスキャン** | 起動時 loadOrScan（キャッシュあれば即） | ゲートなし（初回 UX 優先・軽中量） | 数秒（PHAssetCollection 列挙） | オフメイン（Task.detached） |
| **Dropbox 同期**（差分/longpoll） | 接続時に開始・常駐 longpoll（~50s サイクル） | 接続中のみ。通信は回線ポリシー | ネットワーク待ちが主・CPU 軽。起動時の cachedItems 67k ロード ~1s | オフメイン（actor） |
| **バックアップ**（端末→Dropbox） | 設定 ON＋接続時に評価 | backgroundAllowed＋networkAllowed | アップロード帯域が主 | オフメイン |
| **サムネ取得/先読み**（Dropbox） | クラウド系グリッドのスクロールに追従 | ゲートなし（閲覧体感優先・意図的）。ドレイン中は逆に重い処理を止める側 | 25枚/リクエスト×並列（設定可）。デコードはセマフォ（コア×2）で有界 | オフメイン |
| **メタデータ先読み**（ローカル） | 写真ロード後 | ゲートなし（軽量：メタ4項目×50件チャンク＋yield） | 極軽 | オフメイン（actor） |
| **計測センサー**（Watchdog/TICK） | Performance tracing ON のときのみ | トグル連動 | 無視できる（OFF 時ゼロ） | 専用キュー |

## フォアグラウンド（メインスレッド）に残る処理

体感に直結する順。いずれも「ユーザー操作の直接応答」なのでメイン実行自体は正当。数値は実測。

| 処理 | 重さ（実測） | 状態 |
|---|---|---|
| **グリッドのレイアウト切替**（ピンチで列数変更） | `grid.layout` 24〜374ms（67k・列数による） | 単発なので許容。気になるなら次の候補 |
| **グリッド snapshot の反映**（applySnapshotUsingReloadData） | メイン部分 ~100–150ms（構築 67〜790ms はオフメイン済み） | 許容 |
| **画面遷移の初期化**（ソース画面 onAppear） | `screen.grid.*` 280〜330ms（大規模ソース） | 許容（PerfTrace で監視継続） |
| SwiftUI 差分・PHImage コールバック・セル反映 | 各 ~ms 級 | 正常 |

## 解消済みの主要問題（経緯）

1. 67k 非 lazy TabView（14s→0.2s）
2. generate 純計算のメイン実行（12s ハング）→ Task.detached（A）
3. サムネ要求の MainActor 渋滞（hit で 2.9s）→ detached ストリーム（B・平均 119ms に）
4. **@ModelActor の init スレッド束縛**（14.5s ハングの真犯人）→ オフメイン生成ファクトリ（E1）
5. 起動直後の全処理同時突入（メモリ 668MB→ストール）→ 相互排他（D1）＋アイドルゲート（E2・起動直後は非アイドル）
6. メイン上の PHAsset 全列挙・cloudPhotos 67k map 等 → detached（F1/F2/D3）

## 残課題（更新: 2026-07-05 に主要2件を解消）

- ~~AIAlbumService（@MainActor）の再評価~~ → **解消**: スコアリング（searcher.search）と
  カタログ構築（85k 集計）を Task.detached へ（`AIAlbumService.rankedSearch` / `buildCatalogOffMain`）。
- ~~スクリーンロック中の実行~~ → **解消**: `BGProcessingTask` を導入（`HeavyWorkScheduler`・
  識別子 `com.kanai.MosaicPhotos.heavywork`）。バックグラウンド遷移時に予約し、
  **電源接続中（requiresExternalPower）に OS が起動**して generate 差分・CLIP 埋め込み・
  顔スキャンを進める。期限切れは Task キャンセルで即応。部分 Info.plist（`Config/Info.plist`・
  GENERATE_INFOPLIST_FILE とマージ）で UIBackgroundModes/PermittedIdentifiers を宣言。
- アイドルしきい値 60 秒（`BackgroundYield.heavyWorkIdleSeconds`）は実機の体感で調整可。
- CLIP モデル初回ロード（16–35s・背景）は埋め込み初回要求時の遅延ロード＝実質アイドル時
  （埋め込み自体がアイドルゲート内でのみ動くため）。

## 追加チューニング（T1〜T6・2026-07-05）

- **T1 CLIP タワー分離ロード**: 両タワー同時ロード（16〜35s・+150MB）をやめ、テキスト塔（軽）は
  必要時に即・**画像塔（重）は heavy ゲート内の初回埋め込み時のみ**ロード。起動直後の ANE/CPU/メモリ
  スパイクがユーザー操作の時間帯から消える。タワー別のロード時間をログに記録。
- **T2 Dropbox ディスクヒットの行列解消**: 真因は (1) LRU touch が**ヒット 1 件ごとに SQLite save**、
  (2) キャンセル済みセルの要求もデコードし切る、(3) memHit ですら actor hop。→ touch を 5 分窓で
  スロットル＋save 50 件バッチ化（eviction 前に flush）、limiter 取得後の Task.isCancelled で無効
  デコードを破棄、nonisolated fast path（cachedThumbnail）で memHit の actor キュー待ちを除去。
  計測も queueMs / diskHit（実デコード）に分離。
- **T3 顔スキャン単価**: 検出解像度 800→640px（ロード/メモリ 36%減）＋ recordScan の save を
  写真毎→バッチ毎（8→1 回）に。13k 枚 backlog の総時間と SQLite 負荷を削減。
- **T4 EXIF 列挙のメモリスパイク**: PlaceScanner / PhotoEnricher の EXIF 読み（元データ同期取得）を
  autoreleasepool で 1 アセットごとに解放（初回スキャンの +100〜300MB スパイク対策）。
- **T5 AI 再評価の時間スロットル**: 48 バッチ間引きに加えて「前回から 5 分未満かつ残ありならスキップ」。
  72k backlog 消化中のベクトル読みを累計 ~1.2GB → 数十 MB 規模へ（完了時は必ず反映）。
- **T6 ズームのレイアウト切替**: セクションヘッダを .estimated → 計算値 .absolute にし、
  最大 129 セクションの measure パスを除去（grid.layout 374ms の短縮を狙う・実測待ち）。
