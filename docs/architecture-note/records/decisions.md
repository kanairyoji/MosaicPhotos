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

## ADR-42 夜間の自動バックアップ（重い処理ウィンドウへの相乗り）＋状況表示
- 状態: 採用
- 文脈: バックアップは手動「Back Up Now」のみで、アプリを開いたまま完走を待つ必要があった。一方、AI 索引（タグ/埋め込み/キャプション/顔）は夜間の BGProcessingTask（電源＋Wi-Fi＋非使用・ADR-25）で自動進行しており、バックアップも同じ条件で動くのが自然。また「どこまでバックアップされているか」が実行中の進捗（N/M）以外に見えなかった。
- 決定: (1) `HeavyWorkScheduler.runHeavyWork` の夜間シーケンスに `BackupEngine.startNightlyIfEnabled()` を追加。宛先が Dropbox のときだけ、**手動と完全に同じ経路**（1 回の上限設定・電源/回線ポーズ・ADR-40 の検証つきアップロード・ADR-41 の端末フォルダ）で実行する。BGTask の完了待ちループにバックアップ実行中を加え、**期限切れ時は明示キャンセル**（「済み」記録は hash 検証後にしか付かないため、中断しても次回差分から安全に再開）。(2) `BackupEngine.backupStatus()`（対象総数・完了数。ライブラリ全列挙はオフメイン・完了数は現存写真との積集合＝削除済みを数えない）を追加し、バックアップ画面の先頭に「バックアップ済み X / Y・残り N 枚は夜間に自動で進みます」を常時表示。
- 結果: 放っておけば夜間に少しずつ全量バックアップされる（既定上限 10 枚/回のため、全量を急ぐ場合は上限を無制限へ）。状況が数字で見えるため「動いているのか」の不安が消える。トレードオフ: 夜間ウィンドウを AI 索引と分け合う（どちらもトリクル・譲り合いは既存ゲートに従う）。
- 関連: `HeavyWorkScheduler.swift`・`BackupEngine.startNightlyIfEnabled/backupStatus`・`BackupSettingsView`（状況行）。ADR-25/40/41 の続き。

## ADR-41 バックアップの端末フォルダ分離（家族での Dropbox アカウント共有対応）
- 状態: 採用
- 文脈: 1 つの Dropbox アカウントを家族で共有し、複数端末が本アプリでバックアップする想定。ファイル名衝突による喪失は ADR-40（409 の hash 照合＋autorename）で解消済みだが、**`.mosaic` メタデータ（download→merge→upload 方式）は端末間で後勝ち競合し、相手のエントリを黙って消す**（ADR-38 で「単一端末運用前提」と明記していた制約）。人物名・アルバム所属・オフロード台帳の再構築材料が失われ得る。
- 決定: バックアップの実保存先を `<ルート>/<端末フォルダ>/` に分離する（ファイルも `.mosaic` も端末ごと）。端末フォルダ名は `<表示名>-<短ID>`（例 "iPhone-3F2A8C"）。**短 ID は初回生成して Keychain に永続化**（`BackupDeviceIdentity`・再インストール後も同一。identifierForVendor は再インストールで変わるため不採用・端末名は iOS 16+ で汎用名のみ＋ユーザー変更でフォルダが割れるため不採用）。表示名（UIDevice.model）と ID は catalog.json（deviceID / deviceName）にも記録し、機種変更時の「既存フォルダの引き継ぎ」UI の材料にする。**既存のフラットな旧ファイルは移動しない**（記録はフルパス基準なのでそのまま整合）。メタデータ読み込みは「ルート（旧）＋端末フォルダ（新）」の複数ルート統合（`loadBackupMetadata(from: [String])`）。
- 結果: ファイル衝突とメタデータ競合が構造的に消え、家族共有で安全になった。再インストールは Keychain ID で同一フォルダに向き、アップロード済み記録の消失も 409→hash 照合で自己修復する（ADR-40 との相性）。トレードオフ: (1) Cloud タブでは家族全員の写真が見える（アカウント共有の本質・必要なら将来フォルダフィルタ）。(2) 同一人物の複数端末は独立バックアップ＝共通写真は二重容量。(3) 機種変更時の引き継ぎ UI（フォルダ一覧から選択）は未実装（catalog に材料のみ）。
- 関連: `BackupKit/BackupDeviceIdentity.swift`・`BackupEngine.deviceBackupRoot`・`BackupCatalog.deviceID/deviceName`・`DropboxPhotoStore.loadBackupMetadata(from:[String])`・`BackupDeviceIdentityTests`。ADR-38/40 の続き。

## ADR-40 オフロードの多層防御と検証つきアップロード（content_hash）
- 状態: 採用
- 文脈: オフロード（バックアップ済みローカル写真の削除）はバグが即「写真の永久喪失」になり得る。テスト方法と確実性の設計を先に固めた。調査で現行アップロードに**具体的欠陥**を発見: (1) HTTP 200 を無条件に成功扱い（応答の content_hash 未検証＝壊れた保存を検出できない）。(2) **409（同パス既存）を無確認で「済み」扱い**——同名の別写真（IMG_0001.jpg は普通に衝突する）が「バックアップ済み」と誤記録され、オフロードで消すと永久喪失する。
- 決定: **「削除は証明の後」**を不変条件に多層防御で実装。(a) **検証つきアップロード**＝ローカルで Dropbox content_hash（4MB ブロック SHA-256 連結→SHA-256・`DropboxContentHash` 純関数・独立計算のテストベクタで検証）を計算し、`files/upload` 応答の hash と**一致して初めて「済み」**（不一致は `.hashMismatch`＝絶対に済み記録しない）。409 は `files/get_metadata` で同一性確認→不一致なら **autorename** で別名アップロード。(b) **オフロードの判定**は純関数 `OffloadPlanning.verdict` に集約: Live Photo除外・バックアップ後編集除外・データ取得不能除外・**その場での hash/サイズ完全一致必須**（記録でなくリモート実測と照合）。(c) **実行順序**＝直前再検証 → 台帳記録（先）→ PhotoKit 削除（OS 確認ダイアログ必須・「最近削除した項目」30 日）→ キャンセルなら台帳ロールバック → metadata へ offloadedAt/verifiedAt マーカー。(d) **段階導入**＝ドライラン既定（何も消さない検証一覧）・実削除は Developer Options ゲート＋1 回の上限（既定 10）。(e) **テスト戦略**＝層1: hash/判定の純関数（Python で独立計算した期待値）・層2: 偽 Dropbox（HTTPClient スタブ）＋削除モック（`PhotoDeleter` seam）で「消してはいけない全ケースで削除要求ゼロ」を機械的に保証（クラウド不在/hash不一致/サイズ不一致/読込不能/編集済み/Live/キャンセル→ロールバック/上限/ドライラン）。
- 結果: 削除の前提がすべて実測（今この瞬間の一致）になり、部分アップロード・同名衝突・編集消失の各事故経路がテストで封じられた。トレードオフ: (1) アップロードごとに hash 計算（数 MB で ~10ms・無視可）と 409 時の get_metadata 1 往復。(2) 実機での実削除はテスト用写真での段階運用が前提（ドライラン → 少数 → 拡大）。(3) 動画・Live Photo・iCloud 最適化写真はオフロード対象外（スキップ理由を UI に明示）。
- 関連: `BackupKit/DropboxContentHash.swift`・`DropboxBackupUploader`（検証つき upload / get_metadata）・`BackupRunner`（409 の hash 照合＋autorename）・`OffloadService` / `OffloadPlanning` / `PhotoDeleter` / `PhotoKitDeleter`・`OffloadSettingsView`（ドライラン UI）・`BackupDebugSection`（実削除ゲート）・`DropboxContentHashTests` / `OffloadSafetyTests`。ADR-38/39 の続き。

## ADR-39 オフロード台帳と端末アルバムの合成表示（クラウド代替）
- 状態: 採用
- 文脈: 将来のオフロード（バックアップ済みローカル写真の検証つき削除）後も、端末アルバムを「何事もなかったかのように」表示したい。単純に「metadata の albums 逆引きで、端末に無い写真を全部クラウドから補完」すると、**ユーザーが写真アプリで意図的に削除した写真まで蘇ってしまう**——補完してよいのは「アプリ自身がオフロードした写真」だけであり、その区別には削除の主体を記録する台帳が必要。
- 決定: (1) **オフロード台帳** `OffloadRecord`（@Model・BackupKit ストアに追加）＝アプリが削除した写真の localIdentifier / dropboxPath / 所属アルバム / 撮影日を記録。エンジンがメモリキャッシュ（アルバム名→パス・撮影日昇順）を持ち同期参照できる。再インストール時は metadata v2 の **`offloadedAt` マーカー**（Entry に追加・オフロード実行時にのみ付く）から台帳を再構築（`rebuildOffloadLedgerIfEmpty`・ユーザー削除の写真は対象外）。(2) **端末アルバムの合成表示** `DeviceAlbumPhotosView`＝PHAssetCollection 現存メンバー（ローカル）＋台帳のクラウド代替を、メンバー限定 `MergedPhotoStore` で混在表示（PersonAlbumView / AutoAlbumPhotosView と同型・撮影日ソートで元の位置に混ざる）。台帳が空なら cloudPathFilter が空集合＝従来表示と完全に同一。(3) **アルバム改名対策**＝カタログに `albumIDs`（アルバム名→PHAssetCollection.localIdentifier・マージ保持で旧名対応も残る）を先行追加。
- 結果: オフロード実装時に必要な「削除の主体の区別」「アルバム表示の穴埋め」「改名追跡」の 3 点が先に揃い、削除機能そのもの（contentHash 照合→削除→記録）だけを足せばよい状態になった。現時点では台帳が常に空のため動作は不変。トレードオフ: (1) 台帳キャッシュはアルバム数×オフロード枚数に比例（数万枚規模でも数 MB 級・許容）。(2) アルバム内の手動並び順は撮影日ソートで代替（忠実な再現は将来課題）。(3) 復元（端末へ再取り込み）時の台帳削除 API（`removeOffloads`）は用意済みだが呼び出し元（復元機能）は未実装。
- 関連: `BackupKit/OffloadRecord.swift`・`BackupEngine`（ledger API＋キャッシュ）・`BackupMetadataPlanning.offloadCandidates`・`BackupIndexing.buildAlbumIDIndex`・`DropboxCore/BackupMetadataV2.swift`（albumIDs）・`DropboxBackupMetadata.Entry.offloadedAt`・`MosaicPhotos/Home/DeviceAlbumPhotosView.swift`・`HomeView`（結線）。ADR-38（メタデータ v2）の続き。

## ADR-38 バックアップメタデータ v2（カタログ＋撮影月シャード・再生成不能情報の保全）
- 状態: 採用
- 文脈: 将来「バックアップ済みのローカル写真を端末から削除（オフロード）してストレージを空ける」機能を計画している。削除後もアルバム表示・人物・場所・検索が成立するには、**端末を削除すると再生成できない情報**を Dropbox 側に保全する必要がある。調査の結果、既存 v1（単一 `.mosaic/metadata.json`）には 2 つの問題があった: (1) **欠落** — アルバム/お気に入り/撮影日は保存済みだが、人物名（顔クラスタのユーザー命名＝v1 では常に空）・GPS（EXIF に無い写真は PHAsset が唯一の出典）・localIdentifier（ローカル⇔クラウド対応表）・スクリーンショット判定・VLM キャプションが未保存。(2) **スケール** — 全エントリを毎バックアップで丸ごと書き直すため、6 万枚規模で 15〜25MB/回になる。
- 決定: **v2 = カタログ＋撮影月シャード**へ移行する。`.mosaic/catalog.json`（スキーマ版・シャード一覧・アルバム/人物カタログ・数 KB）＋ `.mosaic/meta/<YYYY-MM>.json`（撮影月ごとのエントリ集・**触った月だけ**ダウンロード→マージ→アップロード）。Entry に Optional フィールドを追加（localIdentifier / latitude / longitude / isScreenshot / caption / verifiedAt）＝ v1 JSON と相互に読める。人物名は `PeopleEngine.peopleNamesByRefKey()`、キャプションは `TagStore` から seam（`peopleNamesProvider` / `captionsProvider`・Composition Root 結線）で取得。**v1 は凍結**（新規書き込みは v2 のみ）とし、読み込み（`DropboxPhotoStore.loadBackupMetadata`）は「v1 ベース → カタログのシャードを上書きマージ」で統合する。シャード決定は UTC の撮影月（端末 TZ 依存だと同じ写真が別シャードに入るため）・日付不明は `undated`。`verifiedAt` はオフロード実装時の「contentHash 照合済み」記録用に先行定義。
- 結果: 再生成不能情報が漏れなく Dropbox に残り、オフロード・機種変更・再インストール後の復元材料が揃う。メタデータ通信は「触った月＋カタログ」に有界化。純ロジック（シャード分割/マージ/カタログ更新）は `BackupMetadataPlanning` に分離し macOS テストで固定。トレードオフ: (1) シャード更新は download→merge→upload の 2 往復/月（同時実行や他端末との競合はラストライター勝ち＝バックアップは単一端末運用前提）。(2) v1 ファイルは残置（読み込み統合でカバー・全量 v2 移行ツールは未実装）。(3) オフロード本体（検証つき削除・refKey 移行・アルバム表示の合成）は次段。
- 関連: `DropboxCore/Models/BackupMetadataV2.swift`（BackupCatalog）・`DropboxBackupMetadata.Entry`（v2 フィールド）・`DropboxPhotoStore.loadBackupMetadata`・`BackupKit/BackupMetadataPlanning.swift`・`BackupRunner`（収集と書き込み）・`DropboxBackupUploader.download/uploadJSON`・`AutoAlbumAdapters`（結線）・`BackupMetadataPlanningTests`。ADR-34（キャプション）・ADR-33（顔クラスタ）。

## ADR-37 AI アルバム作成の入力支援（サジェストチップ＋接地プレビュー＋ヒット件数）
- 状態: 採用
- 文脈: AI アルバムの検索文は自由入力のみで、(1) ライブラリに何があるか（命名済み人物・地名・頻出被写体）を思い出しながら書く必要があり、(2) 書いた文がどう解釈されるか（人物に接地したか・場所が効くか）が作ってみるまで分からなかった。
- 決定: コンポーザーに 3 つの入力支援を追加する（すべて既存の決定的レイヤーの流用＝表示と実検索が乖離しない）。**(1) サジェストチップ** — ライブラリから観測された語をタップで挿入。**確実にヒットする語だけ**を出す: 人物=命名済み顔クラスタ（`namedPeopleProvider`）/ 場所=カタログ実在の地名（`AIAlbumCatalog` 頻度順）/ よく写るもの=頻出タグ（`TagStore.topTags` 新設）∩レキシコン（`japaneseLabel(forTag:)` 新設で日本語表示・表示も接地も保証）/ 日付=パーサ対応の定型（去年・今年・一昨年）。**(2) 接地プレビュー** — 入力の解釈のされ方を色付きチップで表示（人物=ピンク「山田太郎」・場所=緑・視覚語=青「海 → sea」・日付=橙「期間」）。インライン色付けでなくチップ方式＝「太郎 → 山田太郎」の正規化先まで見せられ、`previewInterpretation`/`PersonNameGrounder`/`groundedPairs`（新設）/`RelativeDateParser` の流用で実装が薄い。**(3) ハード条件のヒット件数** — 人物/場所/日付条件があるとき「条件に合致: N 枚」をライブ表示（`QueryEvaluator.hardFilter` をオフメインで・0 件は橙で警告）。基盤は `AutoAlbumEngine+Suggestions`（ライブラリスナップショット 5 分キャッシュ＝タイプごとの 85k 再フェッチ回避・接地プレビューは 350ms debounce）。
- 結果: 空振りしないアルバムをチップから組み立てられ、入力中に「誰・どこ・何が効くか」と概算ヒット数が見える。トレードオフ: (1) スナップショット初回構築（85k lite＋カタログ＋タグ集計）はコンポーザー初回表示時の一拍（以後 5 分キャッシュ）。(2) 件数はハード条件のみ（意味検索込みは重いので出さない・夜間に精緻化の注記を維持）。(3) インライン色付け（AttributedString TextEditor）は Phase 2 候補として見送り。
- 関連: `AutoAlbumEngine+Suggestions`（AIAlbumSuggestions/GroundingPreview/スナップショット）・`TagStore.topTags`・`JapaneseVisualLexicon.groundedPairs`/`japaneseLabel(forTag:)`（public 化）・`AIAlbumComposerView`（チップ UI・debounce）・`LexiconSuggestionTests`。ADR-23（解釈の決定的プレビュー）・ADR-29（人物接地）。

## ADR-36 画像解析はすべて「新しい写真から先に」処理する
- 状態: 採用
- 文脈: 各解析パスの処理順が不定（CLIP 埋め込み＝SQLite の既定順・シーンタグ＝Set 列挙順・キャプション＝refKey 昇順・顔＝PHFetch 既定順）で、撮りたての写真の解析がいつ終わるか運任せだった。ユーザーは新しい写真ほど早く検索・アルバムに反映されてほしい。
- 決定: **全解析パスの供給順を撮影日降順（新しい順・日付なしは最後）に統一**する。(1) CLIP 埋め込み＝`unembeddedRefKeys` に `SortDescriptor(\.captureDate, .reverse)`、(2) シーンタグ＝候補列挙を `enrichedRefKeysNewestFirst()` に、(3) VLM キャプション＝お気に入りを `newestFirst(refKeys:)` で並べ静的キューで処理（TagStore は日付を持たないため AutoAlbumStore 側で整列・動的クエリ→静的キューに変更・実行中の新規は次回巡回）、(4) 顔スキャン＝`localImageRefKeys` に PHFetch の creationDate 降順＋`cloudImageRefKeys` を captureDate 降順ソート（FaceTagger/TagTagger は候補順を保存するため列挙側の整列だけで効く）。
- 結果: 撮りたて・同期したての写真から解析され、検索/アルバム/ピープルへの反映が最速になる。コスト: ソート付き fetch の増分は「512枚ドレインごとに ~数十ms」級で推論（1枚百ms〜秒）に対し無視できる。PHFetch は creationDate 索引済み。トレードオフ: キャプションが動的クエリ→実行開始時の静的キューになり、実行中に増えた対象は次回巡回まで待つ（従来と同じ巡回粒度）。
- 関連: `AutoAlbumStore.unembeddedRefKeys`/`enrichedRefKeysNewestFirst`/`newestFirst(refKeys:)`・`TagStore.captionPendingSet`・`TagTagger.captionUnprocessed(favoritesNewestFirst:)`・`AutoAlbumEngine+Recognition.scheduleBackgroundFill`・`PeopleSupport.localImageRefKeys`/`cloudImageRefKeys`。ADR-30（インターリーブ）・ADR-34（お気に入り限定キャプション）。

## ADR-35 自然文検索の強化: マルチプローブ採点＋候補へのオンデマンドキャプション
- 状態: 採用
- 文脈: 自然文検索を「もっと柔軟に」する構想（ReACT 2フェーズのエージェント検索）の第一歩として、まず**評価ハーネス**（`SearchQualityTests`・Imagenette 200枚×28クエリ・Recall@k）で現行パイプラインを計測した。結果、**精度はほぼ完璧（memberP 0.99）だが言い換え表現の再現率が弱い**（paraphrase-en 0.61 / ja-free 0.68）＝改善ターゲットは「取りこぼしの回収」と数値で確定（model-evaluations §4）。
- 決定: 2 つの決定的強化を導入する。**(A) マルチプローブ採点** — 解釈時（夜間・FM）に `expandProbes`（空振り Refine と同じ単語リスト生成＝小型 LLM が壊れにくい形）で言い換えプローブ（英語・最大4）を生成し `SavedInterpretation.probes` へ永続化（ADR-23 の「解釈は 1 回」を維持・版 v6 採番で既存アルバムも次回夜間に再解釈）。意味採点は主フレーズ＋プローブの **max-over-probes**（どれかの言い回しに近ければ拾う）。採点規則は `QueryEmbedder.semanticScore` に一元化し、フル評価（`searchWithPool`）と増分評価（`refreshIncremental`）が必ず同一規則を使う。**(B) 候補へのオンデマンドキャプション** — LLM 審査（`AlbumVerifier`）の直前に、候補上位のキャプション未生成分へ**その場で VLM を回して証拠を濃くする**（予算 40 枚/審査・生成分は TagStore へ永続化＝再生成しない・シミュレータ/VLM 未同梱は無効）。キャプションのお気に入り限定（ADR-34）の**意図された例外**＝「候補だけに重いモデルを注ぐ」。
- 結果: ハーネス A/B で**言い換え再現率 +17〜18pt**（paraphrase-en 0.61→0.79 / ja-free 0.68→0.85・全体 memberR 0.76→0.86）。精度は 0.99→0.96 と微減だが、本番はこの後段の LLM 審査（B で証拠も濃くなる）が刈る。トレードオフ: (1) 解釈時に FM 呼び出しが 1 回増える（プローブ生成・夜間）。(2) 審査時に VLM 最大40枚 ≈ 3 分弱（夜間・電源＋ロック中ゲート内）。(3) ハーネスのプローブはクエリ集の固定値＝FM 生成品質そのものは実機で別途確認。
- 残課題（ReACT 構想の残り）: Phase 1 の **FM 駆動の絞り込みループ**（観測＝プール集計→行動選択の反復）は未実装。今回の決定的強化で再現率ギャップの大半を回収できたため、残る価値（複雑な複合クエリの反復精化）は実機で A/B してから判断する。実装する場合も「閉じた行動空間・回数上限・決定的フォールバック」の設計（本 ADR 検討時の議論）に従う。
- 関連: `AIAlbum/QueryEmbedder`（QueryVectors.positives・semanticScore 一元化）・`AIAlbumSearch`（probes・public化）・`AIAlbumService`（queryVectors/rankedSearch/refreshIncremental・captionOnDemand 転送）・`AIAlbumInterpretationStore`（probes・v6）・`AIAlbumInterpreter`（プローブ生成・public化）・`AIAlbumVerificationCoordinator`（captionOnDemand・予算40）・`AutoAlbumEngine`（結線）・`MultiProbeTests`・`SearchQualityTests`／`scripts/gen_eval_fixture.py`・`eval_queries.json`。ADR-23・ADR-24・ADR-34・[[model-evaluations]] §4。

## ADR-34 VLM を SmolVLM-500M に格上げ＋キャプションはお気に入り限定にする
- 状態: 採用
- 文脈: SmolVLM-256M のキャプションは曖昧（物体誤認・「文字がある板」止まり）で、テキストベースの意味検索強化の頭打ち要因。より良い VLM を実測比較（`bench_vlm_quality.py`）: **SmolVLM-500M**（Apache・decoder-only＝ANE安全確実）は物体を正しく特定し看板の文字（"Please Prepay"）まで読む＝明確に高品質。SmolVLM2-500M も同等（画像は v1 が素直）。**FastVLM-0.5B は最速・高品質だが `apple-amlr`（研究用途限定）で製品同梱不可**＝不採用。500M は Core ML で **877MB**（デコーダ 691MB fp16・視覚 INT8 94MB・埋込 90MB＝256M の 402MB の約2.2倍）でメモリが律速。実機で自己検証（next-token torch=coreml 一致）・footprint 確認の上で採用。
- 決定: **VLM を SmolVLM-500M へ格上げ**（`convert_smolvlm.py` は `SMOLVLM_MODEL` で差替・視覚のみ INT8 は据え置き・Swift ランタイムは config 駆動で hidden 960 等を自動追従）。さらに **キャプション（重い文章生成）はお気に入り（PHAsset favorite）限定**にする＝タグ/CLIP埋め込み/顔は全写真のまま、VLM だけ絞る。実装: `AutoAlbumEngine.favoriteRefKeysProvider`＋`favoritesCache`（Composition Root が `favoriteImageRefKeys` を注入）／`TagStore.captionPending(favorites:)`・`captionPendingCount(favorites:)`／`captionUnprocessed(favorites:)`／`scheduleBackgroundFill` のインターリーブでお気に入り集合を渡す。進捗分母は**お気に入り数**（`AnalysisProgress.captionableTotal`）、フル画像の「生成中」プレースホルダも**お気に入りのみ**表示。`captionModelVersion` を 6 に採番し旧キャプション破棄＆付け直し。
- 結果: favorite にした写真だけ高品質な一文説明が付く（重い VLM を少数に絞って現実的に）。AI アルバム生成側は**キャプションを元々「任意の補助証拠」扱い**（証拠ゲートは tag か caption・FM 審査の任意コンテキスト・ランキングには不使用）なので**構造変更は不要**（favorite 限定でも破綻しない）。トレードオフ: (1) 500M は 877MB・実機 footprint 増＝メモリ律速（要実機監視）。(2) 非お気に入り・クラウド（favorite 概念なし）はキャプション無し＝テキスト検索の網羅は限定的。(3) お気に入り変更は次回夜間巡回で追従。
- 関連: `scripts/convert_smolvlm.py`(SMOLVLM_MODEL)・`build_smolvlm.sh`・`bench_vlm_quality.py`・`AutoAlbumEngine`(favoriteRefKeysProvider/favoritesCache)・`TagStore`/`TagTagger`(favorites)・`AutoAlbumEngine+Recognition`(scheduleBackgroundFill/insight/analysisProgress)・`AnalysisProgress.captionableTotal`・`AIAnalysisStatusView`・`AutoAlbumAdapters`。ADR-31（CLIP INT8）・ADR-32（Florence撤回）・[[model-evaluations]]。

## ADR-33 ピープル（顔クラスタ）をクラウド写真にも広げる（128px サムネ・追加DL無し・option B）
- 状態: 採用
- 文脈: 顔認識（Vision 検出＋顔モデル埋め込み→クラスタ）は端末写真のみ（候補は PHAsset 列挙・画像は 640px ロード）だった。クラウド（Dropbox）写真でも人物を出したい。ただし顔検出は最も解像度が要る（小さい顔を拾うため端末は 640px）一方、クラウド分析は通信を増やさない方針で**キャッシュ済み 128px サムネ**を再利用している（ADR-24 系）。「品質 vs 通信」で 3 案を提示し、ユーザーが **B（128px で動かす・追加DL無し・低品質許容）** を選択。
- 決定: **クラウド写真も 128px の Dropbox キャッシュサムネで顔検出**する（追加ダウンロード無し・CLIP/タグと同じ経路）。実装: `FacePerceptionAdapter` に `cloudImage` を注入し cloud refKey を処理／候補列挙を `allImageRefKeys`（PHAsset ＋ `dropboxStore.items` の "C-…"）に拡張（4 呼び出し箇所）／人物アルバムを `PersonAlbumView`（メンバー限定 MergedPhotoStore・local+cloud）で表示／代表顔アバター・顔タイルの `loadFaceAvatar` を `HeavyWorkScheduler.stores.dropboxStore` 経由でクラウド対応。顔スキャンの進捗分母もクラウド件数を合算。
- 結果: クラウド写真でもピープルが動き、人物アルバムに端末＋クラウド両方のメンバーが出る。トレードオフ（割り切り）: **128px では小さい/遠い顔を取りこぼし、顔埋め込みも粗く別人誤判定が増える＝大きく写った顔（ポートレート/自撮り）中心**。代表顔アバターも 128px からの切り抜きでボケる。クラウド同期が未完なら候補が空になり得るが、夜間 BGTask/再起動の次回スキャン（増分）で拾う。良い品質が要るなら将来 option C（顔用だけ w256〜640 を 1 枚 1 回取得・通信方針の見直し要）。
- 関連: `MobileCLIPKit/FacePerceptionAdapter`(cloudImage)・`MosaicPhotos/Home/PeopleSupport`(allImageRefKeys/cloudPaths/loadFaceAvatar)・`PersonAlbumView`(新規)・`AutoAlbumAdapters.makePeopleEngine`(dropboxStore)・`HomeView`/`HeavyWorkScheduler`/`AIAnalysisStatusView`(候補列挙)。ADR-29（人物統合・人物名検索）・ADR-24（クラウド分析の 128px 再利用）。

## ADR-32 VLM キャプションを Florence-2-base へ置き換え → **撤回して SmolVLM に戻す**
- 状態: **撤回**（採用 → 実機で破綻し撤回。SmolVLM-256M を継続採用）
- 撤回理由（2026-07・実機検証の結論）: Florence-2-base は Mac の Core ML では全 compute unit で正しく動く（~0.4秒/枚）が、**実機の ANE でも GPU でも fp16 演算が Mac と食い違い、全写真同一の無関係テキスト**（言語モデルの地の文）を吐く。段階切り分けで encoder 出力は有限（fp16 NaN でない）・mask も正常と確認でき、**デコーダの fp16 数値が実機で乖離**（近接 logits の argmax 反転）と判明。fp32 化しても実機 GPU では直らず、`computeUnits=.cpuOnly` なら Mac と一致して正しくなる見込みだが、**CPU 固定では 3〜5秒/枚（Mac 実測 1.3秒）と遅く、Florence を選んだ最大の理由（ANE で 3〜5倍速）が消える**。「CPU 固定なら ANE で速い SmolVLM の方が良い」との判断で撤回。※ SmolVLM が遅くて行き渡らない問題の真因はパイプライン順序バグ（ADR-30）で、それは修正済みのため SmolVLM でも夜間に行き渡る。
- 撤回で戻したもの: `VLMRuntime`（SmolVLM 実行系・視覚埋め込み差し込み＋固定長デコード）・`MosaicPhotos/VLM/`（SmolVLM 資産・`build_smolvlm.sh` で再生成）・`CoreMLModelSupport.makeConfiguration`（cpuOnly 分岐撤去）・`LicensesView`（SmolVLM Apache-2.0）・`CLAUDE.md`。`captionModelVersion` を 5 に上げ Florence の誤キャプションを全消去＆SmolVLM で付け直し。Florence の変換/評価スクリプト（`convert_florence*.py`/`build_florence.sh`/`bench_vlm.py`）は参考として残置。
- 教訓: **Core ML の正しさは Mac だけでは検証しきれない**。encoder-decoder の cross-attention は実機 ANE/GPU の fp16 で Mac と乖離し得る（decoder-only の SmolVLM では顕在化しなかった）。新モデル採用前に**実機での正しさ**を確認する手段（今回の生成ID/有限性ログ）が必須。関連事例は case-studies 参照。
- 以下は撤回前の当初決定（記録として保持）。
- 文脈: 同梱 VLM（SmolVLM-256M・Apache-2.0）は 1枚 1〜2秒（実機）と遅く、夜間バッチでキャプションが行き渡らない一因だった（ADR-30）。「VLM でしか取れない情報は残す」前提で、より軽量・高速なモバイル向け VLM を検討。候補比較（`scripts/bench_vlm.py`・Mac PyTorch MPS）で **Florence-2-base（MIT・約231M）** が SmolVLM（256M）比で自然文キャプションが約5倍速く、内容は同等以上（OCR も滲む）と判明。さらに **Core ML 変換 PoC**（`scripts/convert_florence_poc.py`）で、実機出荷経路の Core ML/ANE でも動作し **~0.4秒/枚**（エンコーダ150ms＋デコーダ6〜7ms/token）＝SmolVLM の 1〜2秒に対し 3〜5倍速が保たれることを確認（※この PoC は Mac の CPU_AND_NE で、実機 ANE の破綻は見抜けなかった）。
- 文脈: 同梱 VLM（SmolVLM-256M・Apache-2.0）は 1枚 1〜2秒（実機）と遅く、夜間バッチでキャプションが行き渡らない一因だった（ADR-30）。「VLM でしか取れない情報は残す」前提で、より軽量・高速なモバイル向け VLM を検討。候補比較（`scripts/bench_vlm.py`・Mac PyTorch MPS）で **Florence-2-base（MIT・約231M）** が SmolVLM（256M）比で自然文キャプションが約5倍速く、内容は同等以上（OCR も滲む）と判明。さらに **Core ML 変換 PoC**（`scripts/convert_florence_poc.py`）で、実機出荷経路の Core ML/ANE でも動作し **~0.4秒/枚**（エンコーダ150ms＋デコーダ6〜7ms/token）＝SmolVLM の 1〜2秒に対し 3〜5倍速が保たれることを確認。
- 決定: **Florence-2-base を採用**（タスク `<DETAILED_CAPTION>` を焼き込み・1文〜数文の自然文説明）。実行方式は encoder-decoder 型: **VLMVision**（画像→encoder隠れ状態＋mask・画像正規化 mean/std とタスクをエンコーダに内包・ImageType scale=1/255）＋ **VLMDecoder**（decoder_input_ids[1,MAXLEN] を固定長で全系列 forward し現在位置の logits を貪欲選択・KVキャッシュ無し・動的長は ANE 非対応のため固定長＝SmolVLM 時代と同方式）。SmolVLM と違い**トークン埋め込み表は不要**（デコーダがトークン ID を直接受ける）＝Swift は復号のみ（`GPT2Tokenizer`・byte-level BPE は BART も同一写像）。encoder/decoder 間は fp16 で直結（キャスト copy 回避）。ビルドは `scripts/build_florence.sh`＋`convert_florence.py`（transformers 4.49 固定＝remote code の都合・ランタイムは Core ML なので無関係）。`captionModelVersion`(1→2) を採番し、起動時 `TagStore.resetCaptions()` で旧 SmolVLM キャプションを 1回クリア→新モデルで付け直す（`captionPending` は `caption==nil` のみ対象＝クリアしないと旧が残るギャップを塞ぐ）。ライセンスは HF モデルカードで MIT を確認。
- 結果: キャプションが 3〜5倍速くなり、内容は同等以上＋看板文字（OCR）まで拾える。同梱サイズは 442MB（VLMVision 258＋VLMDecoder 184）で SmolVLM 491MB より僅かに小。トレードオフ: (1) 全写真の再キャプション（夜間・段階的）。(2) 固定長デコーダは O(L²) 再計算だが 〜48 token で ~0.3秒＝許容。(3) Florence の remote code は transformers 4.49 でしか変換できない（ビルド環境の固定で対応）。(4) タスク展開の落とし穴＝task_ids は processor 経由で作る必要（literal トークン化はタスク名をエコー・変換時に踏んで修正）。(5) 検証は Mac Core ML(CPU_AND_NE)＋Python 復号一致まで（実機 ANE の最終確認は要・シミュレータは VLM スキップ設計）。phase 2 で Florence の INT8 化（~230MB）や OCR/領域タスクの活用余地。
- 関連: `MobileCLIPKit/VLMRuntime`(Florence 化)・`GPT2Tokenizer`(復号流用)・`VisionTagAdapter`(seam 不変)・`scripts/convert_florence.py`/`build_florence.sh`/`convert_florence_poc.py`/`bench_vlm.py`・`AutoAlbumEngine.captionModelVersion`(1→2)・`TagStore.resetCaptions`・`AutoAlbumSettingsKeys.captionModelVersion`・`LicensesView`(MIT 表記)。[[ADR-30]]（インターリーブ）・[[ADR-24]]（多層 AI）。

## ADR-31 CLIP を INT8 重み量子化して容量を半減する（精度ほぼ不変）
- 状態: 採用
- 文脈: 同梱 CLIP（OpenCLIP ViT-B-32/DataComp・fp16）は 289MB（画像168＋テキスト121）と大きい。「似た精度で軽く」を目標に、現行fp16／INT8量子化／TinyCLIP-40M の3構成を Core ML で実測比較した（`scripts/bench_clip.py`・Imagenette×1000クラス zero-shot・Mac CPU）。結果: 現行 289MB/75.0%、**INT8 145MB/76.0%**、TinyCLIP 161MB/61.0%（fp32では67%だが fp16変換で低下）。TinyCLIP は −14pt と精度低下が大きく、テキスト側の語彙埋め込み表で 161MB と INT8 より重い＝不採用。
- 決定: **現行 ViT-B-32 を INT8 重み量子化（`linear_quantize_weights`・linear_symmetric・weight_threshold=512）**して据え置く。モデル・埋め込み次元(512)・入力経路すべて不変。容量 **289→145MB**、精度は 75→76%（誤差・量子化ノイズ）、メモリも微減。CPU では速度同等（重みのみ量子化＝計算時 fp16 に復元）、実機 ANE ではメモリ帯域減で微有利の見込み。`scripts/convert_clip.py` に `QUANTIZE=int8` パス（`maybe_quantize`）を追加、`build_mobileclip.sh` は既定 ON。`perceptionVersion` を 7→8 に採番し、起動時 `resetSceneTagged()` で全写真を**再埋め込み**（埋め込み値が僅かに動くため。数晩・夜間トリクル）。
- 結果: 同梱容量が半減し、精度・機能は不変。トレードオフ: (1) 再埋め込みが 85k 枚ぶん走る（夜間・段階的）。移行中は旧fp16と新INT8の埋め込みが混在するが、同一モデルの量子化差はごく小さく検索への実害は軽微（別モデル差し替えと違い空間がほぼ動かない）。(2) テキスト側量子化で inf を含む const 1つが「量子化スキップ」警告（fp16 のまま残り無害）。(3) 実機 ANE での fp16/INT8 NaN はランタイムの有限性チェックが nil 落としで保険。
- 関連: `scripts/convert_clip.py`（maybe_quantize）・`scripts/build_mobileclip.sh`（QUANTIZE 既定int8）・`scripts/bench_clip.py`（3構成比較）・`AutoAlbumEngine.perceptionVersion`(7→8)・`AutoAlbumStore.resetSceneTagged`。[[ADR-11]]（fp16 image encoder）。

## ADR-30 CLIP 埋め込みと VLM キャプションを夜間バッチでインターリーブする
- 状態: 採用
- 文脈: 実機で VLM キャプションが 1 枚も出力されない不具合。原因は `scheduleBackgroundFill()` のパス順が **タグ → CLIP 埋め込み（全量）→ キャプション** の逐次で、キャプションが**埋め込みの完了を待つ**構造だったこと。実機は 85,418 枚中 17,981 枚（約 21%）しか埋め込めておらず（毎晩の電源＋アイドル窓は短く、1 枚 ANE でも枚数が多い）、埋め込みが 100% になるまでキャプションが 1 枚も始まらない＝事実上キャプションが永遠に未着手だった。
- 決定: 埋め込みとキャプションを**少量ずつ交互（ラウンドロビン）に回す**。タグ（数十 ms/枚・検索の一次ランキング）は従来どおり先に全量へ行き渡らせ、その後 `while !heavyShouldPause()` で「埋め込み 12 バッチ → キャプション 3 バッチ」を繰り返す。各ランタイムに `maxBatches` を渡してバッチ数で切り上げられるようにし（`PhotoTagger.embedUnprocessed` は既存、`TagTagger.captionUnprocessed` に追加）、`AutoAlbumStore.unembeddedCount()` と `TagStore.captionPendingCount()`（新設）で **1 ラウンドの前後差** を見て、両方とも 1 枚も進まなければ終了する。この終了判定はシミュレータ（埋め込み・キャプション両方 `#if targetEnvironment(simulator)` でスキップ）でも安全に即終了する。譲り条件は従来と同じ（埋め込み＝操作中も譲る＋`heavyShouldPause`、キャプション＝`heavyShouldPause`）。
- 結果: 埋め込みが未完でもキャプションが並行して進み始める。停止判定は 1 枚単位のまま（ロック解除直後の操作は即譲る）。トレードオフ: (1) 埋め込みの全量完了は交互ぶん僅かに遅くなる（キャプションに窓を分けるため）が、両者とも「数晩がかり」の性質なので体感差は小さい。(2) ラウンドの前後差カウント（`fetchCount` 2 回/ラウンド）が増えるが、12+3 バッチ＝60 枚超に 1 回なので無視できる。(3) バッチ比（12:3）は実機の 1 枚所要（埋め込み速い・キャプション遅い）に合わせた暫定値で、`BackgroundProcessing` プリセット化は将来課題。
- 関連: `AIAlbum/AutoAlbumEngine+Recognition.scheduleBackgroundFill`・`Perception/PhotoTagger.embedUnprocessed`（maxBatches）・`Tags/TagTagger.captionUnprocessed`（maxBatches 追加）・`Tags/TagStore.captionPendingCount`（新設）・`AutoAlbumStore.unembeddedCount`・`BackgroundTrickle`。ADR-24（多層 AI・夜間トリクル）・ADR-25（電源＋Wi-Fi＋ロック中）。

## ADR-29 ピープルの人物統合と、AI アルバムの人物名検索（決定的接地＋LLM 補強）
- 状態: 採用
- 文脈: (1) 同一人物が顔クラスタリングで 2 人物に割れることがあり、まとめる手段が無かった（1 顔ずつの付け替えのみ）。(2) 人物アルバム名はフルネーム（「木村太郎」）が多いのに、AI アルバムのクエリで名だけ（「太郎」）や複数人物（「太郎と花子」）を指してもヒットしなかった。原因は評価（`QueryEvaluator` の people 部分一致）ではなく、**接地**（サニタイズがカタログ完全一致 or 原文出現しか通さない・"Person N" 混じりカタログ）と**解釈器の出力**（人名抽出は夜間 LLM のみ・作成時プレビューでは立たない）にあった。
- 決定: **(A) 人物統合** — `FaceClustering.merging`（生合計の加算＝加重平均重心・1 顔ずつ adding と等価）＋`FaceStore.mergeClusters(from:into:)`（顔の一括付け替え・sum/count マージ・統合元削除・clusteringCache 無効化）＋`PeopleEngine.mergePerson`。UI は長押しメニュー「別の人物へ統合…」→ ピッカー → 確認。名前・代表写真は統合先を優先。**(B) 人物名検索** — 決定的な純ロジック `PersonNameGrounder` を主軸に据える。名前付きクラスタのフルネーム一覧（`PeopleEngine.namedClusterNames`・"Person N" 除外）をカタログに、クエリ原文から各フルネームの「全体＋前方（姓）＋後方（名）の部分文字列（長さ2以上・中間片は作らず誤爆抑制）」で照合し、該当フルネームを `.people(...)` 条件（部分一致 OR）に載せる。**作成時プレビューと夜間解釈の両方で接地**するので、LLM 非依存で即ヒットする（夜間 LLM はあだ名・ローマ字ゆれの補強）。カタログは `AutoAlbumEngine.setNamedPeopleProvider` で Composition Root から注入。視覚語抽出は人名部分を除いた残りで行う（「花子」の「花」を flower と誤抽出しないよう `strippingNames`）。
- 結果: 割れた人物をまとめられ、「太郎」「太郎と花子」「木村（姓で同姓全員）」がヒットする。純ロジックはテスト済み（merging の加算等価・接地の姓名部分一致・中間片非マッチ・視覚語の誤抽出回避）。トレードオフ: (1) 統合は自動 undo なし（確認アラートで担保）。(2) 接地は `EnrichedPhoto.people`（索引時に焼き込み）を評価するため、リネーム/統合の直後は再エンリッチまで旧名が残り得る（既存の版管理＝criteria 変更/version bump で追従）。(3) 複数人物は OR（「両方写る」AND 生成経路は今回入れていない）。
- 関連: `Faces/FaceClustering.merging`・`FaceStore.mergeClusters`・`PeopleEngine.mergePerson`/`namedClusterNames`、`MosaicPhotos/Home/PersonPhotosView`（PersonMergePickerView）・`PeopleActions`、`AIAlbum/PersonNameGrounder`・`QuerySpecSanitizer.addingPeople`・`AIAlbumInterpreter`（preview/interpretation）・`AIAlbumService`・`AutoAlbumEngine.setNamedPeopleProvider`・`AutoAlbumAdapters`。ADR-23（解釈の永続化）・ADR-24（people 部分一致）。

## ADR-28 フル画像の情報パネルに抽出情報を漏れなく出す（顔数・スクショ。CLIP はラベル化済み）
- 状態: 採用
- 文脈: 「画像から抽出した情報は全てフル画面に出したい」との要望。監査の結果、写真 1 枚から永続化している情報のうち **顔の数**（`ScannedPhoto.faceCount`・実測）と **スクリーンショット判定**（`PhotoEnrichment.isScreenshot`）が `PhotoInsight` 型に載っておらず、`insight()` が構築時に捨てていて画面に出ていなかった。CLIP 512 次元ベクトル（`PhotoEmbedding.vector`）は生では意味不明だが、既に `CLIPDisplayLabeler`（約300語ゼロショット・最大6語）で語化され Vision シーンタグと統合して「Detected」欄に表示済み（＝ベクトルのキーワード化は実装済み・眠っていない）。
- 決定: `PhotoInsight` に `faceCount: Int?`（未スキャン=nil で「0 と未計測」を区別）と `isScreenshot: Bool` を追加。顔数は `FaceStore.faceCount(refKey:)`（単一・軽い fetch）→ `PeopleEngine.faceCount(forItemID:)` を新設し、人物名と同じく `SourceHostView` の photoInsight クロージャで合成（顔スキャンは端末のみ＝クラウドは nil）。isScreenshot は `insight()` が `rec.photo` から詰める。パネルは、人物名があれば「名前 · N faces」、名前が無くても顔スキャン済みなら「N faces（Detected faces）」を出し、スクショは「Screenshot」バッジを出す。CLIP ラベルは現状の統合表示を維持（生ベクトルは出さない）。
- 結果: 抽出済みの情報がフル画面に出揃った（タグ＝Vision＋CLIP語化・キャプション・人物名・顔数・スクショ・場所・日付・EXIF・地図・解析状態）。未表示のまま残すのは内部値（aspect・contentHash・linkKey・顔 bbox/embedding）と、AI 抽出でないユーザーフラグ（isFavorite＝別途ハートで表示）。
- 関連: `PhotoInsight.swift`、`PhotoInfoPanel.insightSection`、`AutoAlbumEngine.insight`、`PeopleEngine.faceCount(forItemID:)` / `FaceStore.faceCount(refKey:)`、`SourceHostView`。CLIP 語化は `CLIPDisplayLabeler`。

## ADR-27 AI 解析の進捗をユーザー向けに可視化（各パスの最終実行時刻を永続化）
- 状態: 採用
- 文脈: オンデバイス AI（意味検索の CLIP 埋め込み・シーンタグ・キャプション・顔スキャン）は既定でフォアグラウンド停止＝夜間トリクル（ADR-25）のため、ユーザーからは「動いているのか・どこまで済んだのか」が全く見えなかった。進捗の数値は Developer Options や AutoAlbumSettings に断片的に出ていたが、デバッグ用で分散し、最終実行時刻はBGタスク全体（`bgTaskLastRun`）しか無かった。
- 決定: 設定「Albums & Search」に**ユーザー向け専用画面「AI Analysis（AI 解析の状況）」**を新設。(1) 各パスの「完了数／総数（進捗バー＋%）」を表示（分母は取り込み済み写真数＝`enrichmentCount`。CLIP/タグ/キャプションで共有、顔は端末写真数）。(2) **各パスの最終実行時刻を新規に永続化**＝`AnalysisActivity`（UserDefaults・パス別キー）を各タガーの**バッチ確定点で記録**（実際に 1 枚以上処理したときだけ＝空振りで更新しない＝「止まっている」を正しく反映）。(3) 「解析中」は `BackgroundActivityMonitor`（ライブ）を body 直読みで即時反映。(4) 集約取得は `AutoAlbumEngine.analysisProgress()`（1 回で total/embedded/sceneTagged/captioned）と `PeopleEngine.scanStats()` を新設（従来 internal だった TagStore/FaceStore の件数を public 委譲で薄く露出）。キャプション/顔はモデル未同梱ならセクション非表示。デバッグ用の詳細（Developer Options）は従来どおり別に残す。
- 結果: 「動いていない／完了したか分からない」が解消。文字列は英語 base＋日本語訳を String Catalog に追加（補間キーは位置指定 `%2$lld…%1$lld` で語順対応）。トレードオフは公開 API と UserDefaults キーが増える点、及び分母を `enrichmentCount` で近似する点（取り込み前の写真は母数に入らない＝生成前は 0/0 と出る）。
- 関連: `MosaicPhotos/Settings/AIAnalysisStatusView.swift`、`AutoAlbumCore/AnalysisActivity.swift`（`AnalysisProgress` 含む）、`AutoAlbumEngine+Recognition.analysisProgress()`、`PeopleEngine.scanStats()`、各タガーのバッチ確定点。ADR-25（夜間トリクル）。

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

## ADR-26 横断リファクタリング＝共通足場の抽出と肥大型の責務分割（挙動不変）
- 状態: 採用
- 文脈: 機能追加が続き、同じ骨格のコピーが層をまたいで蓄積（背景トリクル 4 ループ / 自己修復 ModelContainer 3 実装 / Core ML ランタイム 3 種のロード・推論 / BPE トークナイザ 2 種の足場 / UI 小物パターン約 25 箇所）。また最大級の型（AIAlbumService 462 行・BackupEngine 346 行・DropboxThumbnailBatcher 329 行）に複数責務が同居し、変更の影響範囲が読みにくくなっていた。
- 決定: **挙動不変（ログ文言・PerfTrace ラベル・public API・永続化フォーマット・見た目を維持）**を絶対条件に、(1) 共通足場の抽出＝`BackgroundTrickle`（1 枚単位の譲り骨格・AutoAlbumCore）/ `makeResilientModelContainer`（MosaicSupport）/ `CoreMLModelSupport`・`BPESupport`（MobileCLIPKit。bpe() 本体は CLIP=最左 1 箇所マージと GPT2=全出現一括マージでアルゴリズムが異なるため共通化しない）/ `BusyLabel`・`LoadingRow`・`sectionHeader`・`loadCover`（アプリ層）、(2) 責務分割＝AIAlbumService→`AIAlbumInterpreter`/`AIAlbumVerificationCoordinator`/`QueryEmbedder`（フル評価と増分評価の「同じ規則」不変条件をコピペ同期から型共有に）、BackupEngine→`BackupRunner`/`BackupProgressStore`、Batcher→`DropboxThumbnailBatchRequest`(純)/`DropboxThumbnailChunkFetcher`。あわせて死線（旧行ベースのホーム行 3 型）と誤情報（Minimum iOS 表示）・既定値リテラルの散在を整理。
- 結果: 譲りポリシー・コンテナ復旧・モデルロードの方針変更が各 1 箇所で済む。トークナイザは同梱語彙での並置比較でビット等価を実測確認。キュー戦略・審査規則が独立テスト可能に。トレードオフはファイル数の増加と、共通骨格（BackgroundTrickle 等）への間接参照が 1 段増えること。
- 関連: コミット a07e38b8〜dcea41af（7 コミット）。ADR-25（1 枚単位の停止判定）・ADR-23/24（同じ規則の不変条件）。

## ADR-25 重い処理は「電源＋Wi-Fi＋画面ロック中」のみ実行（フォアグラウンド完全停止）
- 状態: 採用（ADR-20/ヘビーワークゲートの後継）
- 文脈: 旧ゲートは「電源＋低電力OFF＋アイドル60秒」。充電しながら閲覧中に60秒触らないと重い処理（顔認識・タグ付け・再評価）が走り出し、操作再開時にバッチ途中（クラウド写真のタグ付けは1バッチ最大約27秒）が譲れず操作が固まった。「操作あり」の検出も狭く（ホームのスクロール等はアイドル扱い）、誤発火した。ユーザー方針:「操作中は一切動かさない。電源＋Wi-Fi＋ロック中に動かす。AIアルバム作成もなるべくそのタイミングに」。
- 決定: (1) 中央ゲート `BackgroundYield.heavyWorkAllowed` を「電源＋低電力OFF＋**アプリ非アクティブ（scenePhase）**＋**Wi-Fi**」へ変更しアイドル判定を廃止。手動ブースト（今すぐ処理）だけ非アクティブ/Wi-Fi を免除。BGTask 起動時は scenePhase 変化が来ないため `runHeavyWork` 冒頭で非アクティブを明示（初期値 true のままゲートが開かない罠）。(2) 停止判定を **1 枚単位**に統一（タグ/顔/キャプション。CLIP は既に1枚単位）。(3) AI アルバム作成は**2段階**＝作成時は決定的プレビュー（レキシコン＋日付＋タグ照合・LLMなし・1〜2秒・`pendingFinalization`）→ 夜間に `finalizePending`（FM解釈＋証拠ゲート＋LLM審査＋Refine）で本番化。(4) 場所の定期再スキャンにも同ゲート適用。(5) 表示ラベラの概念埋め込み（約300語）を夜間パイプライン先頭で prewarm（写真初回オープンの数秒負荷を排除）。(6) 作成画面に動作タイミングの説明（プレビュー→夜間本番化）を明記。
- 結果: フォアグラウンドでは重い処理が一切走らず操作が軽くなる。索引の進行は「充電＋Wi-Fi＋ロック」時間帯に限定され初回全量は日数を要する（エスケープハッチ=今すぐ処理）。BGTask は OS 裁量のため毎晩の実行保証はない。
- 関連: `BackgroundYield` / `MosaicPhotosApp`（scenePhase）/ `HeavyWorkScheduler` / `TagTagger`・`FaceTagger`（1枚粒度）/ `AIAlbumService.previewInterpretation`・`finalizePending` / `AIAlbumComposerView`。ADR-20・ADR-23・ADR-24。
- 追記（2026-07-08・5段階のユーザー設定化）: 固定ゲートをやめ、**実行タイミングをユーザーが 5 段階で選択**できるようにした（`HeavyWorkTiming`・既定は従来どおり「おまかせ＝夜間のみ」）。段階は単調に条件を緩める: 一時停止 → おまかせ（電源+Wi-Fi+非使用）→ 充電中はアプリ使用中の合間も（アプリ内全タッチを `TouchActivityTracker`（UIWindow 上の認識器）で捕捉し 20 秒アイドルで開始・タッチ即停止）→ バッテリーでも（残量 20% 以上）→ 制限なし（モバイル回線も）。低電力モード・メモリ圧迫は全段階でブロック（安全弁）。battery 以上では BGTask の `requiresExternalPower` も外す。判定は純関数 `HeavyWorkTiming.allows`（単調性を総当たりテストで固定）。設定 UI は AutoAlbumSettingsView「処理のタイミング」（各段の条件と影響を footer に明記）。

## ADR-24 AI アルバム検索を「タグ台帳＋LLM審査」へ再設計（閾値レス・エージェント型）
- 状態: 採用（ADR-23 の検索段を拡張）
- 文脈: 生 CLIP コサイン＋絶対閾値（floor 0.20 / 除外 0.22）の検索は、ユーザーのライブラリ分布が事前に不明なため閾値を調整できず、実測で「除外が全写真の 97% を落とす」「意味採用 0 件」が発生。小型オンデバイス LLM の構造化出力も 3 回連続で異なる形に壊れた（例語オウム返し・"any" プレースホルダ・「ここ2年」→year 2026）。ユーザー方針: 精度優先・夜間バッチは数日かかってよい・辞書は 300 語では不足。
- 決定: 4 層の再設計。(1) **P0 接地**＝日付は RelativeDateParser を唯一の出典・place/people はカタログ/原文出現のみ・翻訳失敗の非キャッシュ（解釈 v4）。(2) **P1 タグ台帳**＝OS 内蔵 Vision 分類（約1,300クラス・`hasMinimumRecall(forPrecision:)` の校正済み足切り＝自前閾値が消える）を夜間トリクルで全量付与（TagsV1 別コンテナ）し、タグ一致（離散・閾値レス）を第 3 のランキングとして RRF 融合、除外語はタグの離散一致でもハード除外。(3) **P2 LLM 審査**＝候補上位 60 件の証拠行（日付・場所・顔数・タグ・キャプション）を FM が keep/drop/unsure 判定し、unsure は最大 2 回の再判定で**多数決**（同数は keep＝安全側）。空振り時は LLM がプローブ語を生成して 1 回だけ再検索（Refine）。(4) **P3 VLM キャプション**＝SmolVLM-256M（Apache-2.0・約 500MB 同梱）で写真ごとに英語短文を夜間生成（1〜2 秒/枚・数晩がかり）し、審査の「目」にする。語彙制約が構造的に消える。
- 結果: 閾値依存がほぼ消滅（タグ=写真内順位・審査=言語判定）。判定根拠がタグ/キャプションで可視化されデバッグ可能。トレードオフ: バンドル +約500MB（VLM）・索引はカバレッジ依存（未索引写真は検索に弱い＝優先埋め込みで緩和予定）・審査は FM 搭載端末のみ（無ければ素通し）。
- 関連: `TagStore/TagTagger/VisionTagAdapter` / `AlbumVerifier` / `VLMRuntime/GPT2Tokenizer` / `scripts/build_smolvlm.sh`。ADR-19（権利フリーモデル）・ADR-23。事例「否定条件が二重に不発」「LLM 構造化出力の連続破綻」。

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
