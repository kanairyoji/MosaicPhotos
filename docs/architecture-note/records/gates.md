# ゲート（純ロジックの判断）の台帳 — マスター

> このファイルは **「重い処理をやるか・やらないか」を決める純ロジック**の一覧です。
>
> **運用ルール**
> - 新しいゲート（`*Gate` / `*Policy` / `AnalysisTurn` のような判断の純 enum）を足したら、
>   **必ずここに 1 項追記する**。`scripts/check_gate_ledger.py` が CI で突き合わせ、
>   書かれていないゲートがあると落ちる。
> - 1 項に書くのは **3 つだけ**: **材料**（入力）／**材料に求める性質**（約束）／
>   **その約束を守るテスト**。
> - ⚠️ 「規則のテスト」だけでは足りない。**材料が約束を守っているかを、実物に対してテストする。**

---

## なぜこの台帳が要るか（ADR-251）

判断を純 enum へ出して規則をテストするのは良い方法で、**規則そのものは一度も間違えていない**。
間違いは必ず**その外側**で起きた。

| 修正 | 欠陥の場所 | 見つかった経路 |
|---|---|---|
| ADR-237（顔とタグを交互に） | **呼び出し側**（明け渡しを `turn == .tags` の内側に入れた） | コードレビュー（出荷前） |
| ADR-243（取れない写真を諦める） | **呼び出し側**（`batch` 差分で**未試行**を失敗に数えた） | 自己レビュー（出荷前） |
| ADR-247（候補の列挙を飛ばす） | ⚠️ **材料**（`itemsRevision` が撮影日の問い合わせでも進む） | **実機ログ（出荷後）** |
| ADR-242（nil を「無い」と読まない） | 呼び出し側（`allClusters()` の `?? []`） | レビュー（出荷前） |

⚠️⚠️ **純ロジックのテストは、材料の穴を原理的に見つけられない。**
材料は引数で与えられるので、「その引数が現実にどう動くか」は**テストの外**にある。
`CandidateEnumerationGate` は規則も材料の取り出しも「正しく」書けていたのに、
実機で **1 回も効かなかった**（`候補の列挙を見送る` が 0 件・8.6 万件を 11 回とも列挙）。

だから**材料ごとに、ゲートが頼っている性質を実物に対して固定する**。
⚠️ あわせて **効いた回数が見えるログ**を必ず付ける——今回それがあったから「0 件」で気づけた。

---

## テンプレート

```
## <ゲート名>（ADR-N）
- 置き場: <ファイル>
- 問い: 何を決めるか（1 行）
- 材料:
  - `<入力>` ← `<出どころ>`
    - 約束: この入力が満たしていなければならない性質
    - テスト: <テスト名>
- 規則のテスト: <テスト名>
- 呼び出し側のテスト: <テスト名>（決定が実際の振る舞いへ届くか）
- 効きを見るログ: `<診断ログの文字列>`
```

---

## CandidateEnumerationGate（ADR-247 / 250）
- 置き場: `MosaicPhotos/AnalysisTurn.swift`
- 問い: 顔スキャンの候補（8.6 万件・約 11 秒）を**列挙する必要があるか**
- 材料:
  - `cloudRevision` ← `DropboxPhotoStore.cachePhotoSetRevision()`
    - 約束: **写真が増えた／減ったときだけ**進む。⚠️ 撮影日の問い合わせ・撮影地の解決・
      中身の差し替えでは**進まない**（進むとゲートが永久に効かない＝実機で起きた）
    - テスト: `PhotoSetRevisionTests`（5 本）
  - `localCount` ← `PHAsset.fetchAssets(...).count`（スクショ除外）
    - 約束: 候補の列挙（`localImageRefKeys()`）と**同じ条件**で数える
    - テスト: （未・条件の二重定義が残っている。下記「残っている宿題」）
  - `scanned` / `unreadable` ← `FaceScanControl.scanLedgerFingerprint()`
    - 約束: 台帳の実数であること。⚠️ **`faceBacklog` を使わない**
      （スキャン側しか更新しないので 0 に張り付き、札を立てると永久に走らなくなる）
    - テスト: `ScanAttemptTests`（外した件数が実数で動くこと）
- 規則のテスト: `CandidateEnumerationGateTests`（5 本・母集合が動く 4 経路すべて）
- 呼び出し側のテスト: （未・`AnalysisDriver` は実機ログで見る）
- 効きを見るログ: `driver: 候補の列挙を見送る`

## TagWorkGate（ADR-247）
- 置き場: `Packages/AutoAlbumCore/Sources/AutoAlbumCore/Tags/TagStore.swift`
- 問い: シーンタグ付けの**重い準備**（8.6 万行 ×2 ＋ソート）をやる必要があるか
- 材料:
  - `enriched` ← `AutoAlbumStore.enrichedCount()`（`fetchCount`）
    - 約束: 写真が増えなければ動かない／増えたら増える
    - テスト: `GateInputContractTests.enrichedCountIsStableWithoutNewPhotos` ほか
  - `tagged` ← `TagStore.taggedCountCurrentVersion()`（`fetchCount` + 版）
    - 約束: タグを付けなければ動かない／付けたら増える／⚠️ **版を上げたら減る**
      （「増えたときだけ走る」にすると版を上げた晩に 1 枚も進まない）
    - テスト: `GateInputContractTests.taggedCountIsStableWithoutTagging` ほか
- 規則のテスト: `TagWorkGateTests`（6 本）
- 呼び出し側のテスト: （未）⚠️ 札を立てるのは `tagUnprocessed` が **0（本当に残り無し）** を
  返したときだけ。走れなかった回は `nil` を返して **0 と混ぜない**
- 効きを見るログ: `tags: 重い準備を見送る（前回から変わっていない enriched=… tagged=…）`

## CaptureDateFillGate（ADR-243）
- 置き場: `Packages/FaceCore/Sources/FaceCore/Faces/FaceStore+CaptureDates.swift`
- 問い: クラウドの顔の撮影日の埋め直しをやる必要があるか
- 材料:
  - `progress` ← `DropboxPhotoStore.exifProbePendingCount()`
    - 約束: EXIF の問い合わせが進めば動く（＝新しい日付が分かり得る）
    - テスト: `CaptureDateProbeTests`（DropboxCore・「二度目は訊かない」「中身が変わったら訊き直す」）
  - `scanned` ← `FaceStore.scannedCount()`
    - 約束: 顔をスキャンしなければ動かない（＝撮影日が空の顔は増えない）
    - テスト: `ScanPendingCountTests` ほか
- 規則のテスト: `CaptureDateFillGateTests`（4 本）
- 効きを見るログ: `faces: cloud capture dates`（**出なくなる**ことで効きが分かる）

## AnalysisTurn（ADR-237）
- 置き場: `MosaicPhotos/AnalysisTurn.swift`
- 問い: この枠で顔とタグ/埋め込みの**どちらを起こすか**
- 材料:
  - `facesRunning` / `tagsRunning` ← `people.isScanning` / `engine.isTagging`
    - 約束: 「走っているか」は**無料で分かる**（DB を引かない）。
      ⚠️ **残作業の数を入れない**（`faceBacklog` は 0 に張り付く）
    - テスト: `AnalysisTurnTests`（残作業を入れない形を注記で固定）
  - `isPrivilegedTrigger` ← 夜間の処理枠 / ブーストの終了
    - 約束: 明け渡し（滞留した実行の置き換え）は**順番の外**で判断する
    - テスト: `AnalysisTurnTests.privilegedTriggerPreemptsStalledTags`
- 規則のテスト: `AnalysisTurnTests`（12 本）
- 効きを見るログ: `driver: turn=` / `driver: 顔の開始を見送る` /
  `driver: 滞留していたタグ/埋め込みを明け渡させた`

## ScanAttemptPolicy（ADR-243）
- 置き場: `Packages/FaceCore/Sources/FaceCore/Faces/FaceStore+ScanAttempts.swift`
- 問い: 画像が取れない写真を**いつ諦めるか**
- 材料:
  - `lastFailureAt` / `now`
    - 約束: 数えるのは**試した上で取れなかった**ものだけ。⚠️ `batch` との差分で数えない
      （譲りで打ち切った＝一度も試していない写真を失敗に数えると、本物の写真が外れる）
    - テスト: `FaceTaggerRecordingTests.doesNotBlamePhotosItNeverTried`
- 規則のテスト: `ScanAttemptTests`（7 本・1 時間に 1 回しか数えない／上限前は外さない）
- 呼び出し側のテスト: `FaceTaggerRecordingTests`（+3 本）
- 効きを見るログ: `faces: N 枚を候補から外す` / `faces: start — … unreadable=N`

## AssetIndexRebuildPolicy（ADR-249）
- 置き場: `Packages/PhotosFeatureKit/Sources/PhotosFeatureKit/LocalAssetIndex.swift`
- 問い: アセット索引（18,204 件）を**いつ作り直すか**
- 材料:
  - `lastChangeAt` ← PhotoKit の変更通知
    - 約束: 通知のたびに更新される（＝変化が続いている間は待てる）
    - テスト: （未・宿題）
  - `lastRebuildAt` / `lastRebuildSeconds` ← 直近の作り直しの実測
    - 約束: **実際に作り直した回だけ**記録する（空振りを混ぜるとバックオフが毎回リセットされる）
    - テスト: （未・宿題）
- 規則のテスト: `AssetIndexRebuildPolicyTests`（5 本）
- 効きを見るログ: `assetIndex: built` の**回数**（103 では 36 回）
- ⚠️ 前提: 遅らせても正しさは落ちない（`needsRevalidation` が立っている間は要求のたびに現存を確かめる）

## FaceQualityGate（ADR-48/52/53）
- 置き場: `Packages/FaceCore/Sources/FaceCore/Faces/FaceSeams.swift`
- 問い: 検出した顔を**クラスタへ入れてよいか**（品質の足切り）
- 材料: 検出信頼度・ぼけ・露出・サイズ・顔向き・目閉じ
  - 約束: ⚠️ **シミュレータでは OS の顔品質が取れず 1.0 になる**ので、
    品質が絡む計測は Mac で取った `os-quality.json` で実機相当にする
  - テスト: `QualityFloorEvalTests`（データセット）
- 規則のテスト: `FaceAccuracyEvalTests` ほか（数値の正本は `face-accuracy.md`）
- ⚠️ このゲートだけは**データセット計測で決める**（体感・個別事例では決めない）

## NightlyWorkPolicy（ADR-163 / 166 / 252）
- 置き場: `MosaicPhotos/NightlyWorkPolicy.swift`
- 問い: この窓でアルバム生成をやるか（解析と共倒れさせないか）／週 1 の照合の期限か
- 材料:
  - `embedBacklog` ← `AutoAlbumEngine.pendingEmbedCount()`
    - 約束: 実数であること
    - テスト: `GateInputContractTests`（`enrichedCount` / `taggedCountCurrentVersion` 経由）
  - `faceBacklog` ← `PeopleEngine.lastKnownFaceBacklog`（**`Int?`**）
    - 約束: ⚠️⚠️ **「分からない」を 0 にしない**。`scanProgressRemaining` はスキャン中以外 0 で、
      `measureBacklogIfUnknown` は**順番が顔の回しか**呼ばれない（ADR-237 で交互）ので、
      タグの回の窓では必ず nil になる。前の起動の記録まで見て、本当に分からないときだけ nil
    - テスト: `FaceBacklogMaterialTests`（3 本・起動を跨いで読めること／この起動の値が勝つこと）
  - `generateDeferrals` ← `UserDefaults`（連続見送り回数）
    - 約束: 見送った回だけ増え、実行した回に 0 へ戻る（戻さないと生成が飢える）
    - テスト: `NightlyWorkPolicyTests.testDeferralStreakCyclesInsteadOfStalling`
- 規則のテスト: `NightlyWorkPolicyTests`（nil を「終わった」にしない 1 本を含む）
- 効きを見るログ: `window plan: …→generate(defer:N)→…`（`RunTimeline`）

## AnalysisDriverPolicy（ADR-195 / 196）
- 置き場: `MosaicPhotos/AnalysisDriver.swift`
- 問い: この契機で解析を起こすか（＋候補の使い回し・空振りの待ち時間）
- 材料:
  - `trigger` / `scenePhase` / ゲート表の判定 ← `BackgroundYield.verdict`
    - 約束: ⚠️ 入口の判定と 1 単位ごとの譲り判定は**同じ式**（ADR-196）。述語を増やさない
    - テスト: `BackgroundYield` のゲート表のテスト（正本は `background-behavior.md`）
  - `emptyStreak` ← 駆動役が持つ空振りの連続回数
    - 約束: **仕事が始まったら 0 に戻す**。戻さないと 30 分待ちに張り付く
    - テスト: `AnalysisTurnTests` / `AnalysisSessionPolicyTests`
  - `cachedAt` ← 候補を列挙した時刻
    - 約束: 列挙に**成功した**時刻だけ入れる（空振りを入れると 10 分間列挙されない）
    - テスト: `AnalysisDriverPolicy.canReuseCandidates` のテスト
- 規則のテスト: `AnalysisTurnTests` / `AnalysisSessionPolicyTests`
- 効きを見るログ: `driver: <trigger> → <decision>`

## AnalysisSessionPolicy（ADR-182 / 207）
- 置き場: `MosaicPhotos/AnalysisSessionPolicy.swift`
- 問い: ブースト（「今すぐ解析」）の進捗と、終わりの理由
- 材料:
  - `faceBacklog` ← `PeopleEngine.faceBacklog ?? 0`
    - 約束: ⚠️ ここは**この起動の実測**でよい（ブースト中はスキャンが走るので値が入る）。
      ⚠️ ただし `peakRemaining` は**観測した最大値**であること（分母が縮むと進捗が巻き戻る）
    - テスト: `AnalysisSessionPolicyTests`
  - `blockers` ← `BackgroundYield.verdict(for:).blockers`
    - 約束: ⚠️ **電池の下限をここで持たない**（ゲート表が唯一の出典。持つとブーストの
      ループの中でしか効かず、「電池のため止めた」直後に方針が再開する＝レビュー指摘）
    - テスト: `AnalysisSessionPolicyTests`
- 規則のテスト: `AnalysisSessionPolicyTests`
- 効きを見るログ: `boost: stop — …`

## BackupReconcilePolicy（ADR-166 / 206）
- 置き場: `Packages/BackupKit/Sources/BackupKit/BackupReconcilePolicy.swift`
- 問い: バックアップ台帳と実体を照合する頃合いか（週 1）
- 材料:
  - `lastRun` ← 台帳の刻印（**nil なら実行**＝初回に基準時刻を作る）
    - 約束: ⚠️ **失敗した回も刻む**（通信断の端末が窓のたびに数万件の一覧を投げないため）。
      ただし失敗の刻印は `stampAfterFailure` で縮める（丸 1 週間遅らせない）
    - テスト: `BackupReconcilePolicyTests`
  - `now` ← 端末の時計
    - 約束: ⚠️ **巻き戻り得る**。差が負なら「間隔が空いた」と扱う（永久に照合されない方が困る）
    - テスト: `BackupReconcilePolicyTests`
- 規則のテスト: `BackupReconcilePolicyTests`
- 効きを見るログ: `window plan: …→reconcile→…`

## CloudReconcilePolicy（ADR-206）
- 置き場: `Packages/DropboxCore/Sources/DropboxCore/Sync/CloudReconcilePolicy.swift`
- 問い: クラウドのキャッシュを全件見直す頃合いか（週 1）
- 材料:
  - `lastFullScan` ← `DropboxSyncState.initialSyncCompletedAt`
    - 約束: ⚠️ **新しい時刻を持たない**。初回同期の掃除が終わった時刻がまさにそれ。
      ⚠️ nil は **false**（「一度も完走していない」の分岐は呼び出し側が既に持っている）
    - テスト: `CloudReconcileTests`
  - `now` ← 端末の時計（巻き戻りは `BackupReconcilePolicy` と同じ規則）
    - テスト: `CloudReconcileTests`
- 規則のテスト: `CloudReconcileTests`

## ModelIdlePolicy（ADR-223）
- 置き場: `Packages/MosaicSupport/Sources/MosaicSupport/ModelIdlePolicy.swift`
- 問い: 使われていないモデルを手放してよいか（再ロードは実機 10〜35 秒）
- 材料:
  - `lastUse` ← **そのモデルを**最後に使った時刻。⚠️ **nil なら手放さない**
    （一度も使っていない＝載っていない。手放してもログだけ増え、`shared` を起こす副作用がある）
    - 約束: モデルごとに別の記録であること（1 つにまとめると片方の利用でもう片方が残る）
    - テスト: `ModelIdlePolicyTests`
  - `analysisRunning` ← **そのモデルを使う処理**が走っているか
    - 約束: ⚠️ `faceRemainingHere`（今ここで進められる残り）を見る。回線待ちのクラウド分を
      含む `faceBacklog` を見ると、Wi-Fi の無い端末で ADR-223 が一度も効かない
    - テスト: `ModelIdlePolicyTests`
- 規則のテスト: `ModelIdlePolicyTests`

## ThermalPolicy（ADR-118）
- 置き場: `Packages/MosaicSupport/Sources/MosaicSupport/ThermalPolicy.swift`
- 問い: 発熱で重い処理を止めるか（守っているのは温度ではなく**充電**）
- 材料:
  - `state` ← `ProcessInfo.thermalState`
    - 約束: ⚠️ 止める境界（`.serious`）と再開の境界（`.nominal`）を**ずらす**。
      同じ境界だと境界付近で止まる→少し冷える→再開を繰り返し、細かく動き続けて冷えない
    - テスト: `ThermalPolicyTests`（ヒステリシス）
  - `batteryLevel` ← 端末の充電率
    - 約束: ⚠️ 98% で「充電は済んだ」と見る（100% ちょうどを条件にすると、満充電付近で
      表示が 99% と行き来するためほとんどの晩で成立しない）
    - テスト: `ThermalPolicyTests`
- 規則のテスト: `ThermalPolicyTests`

## MergePolicy（ADR-213 / 153）
- 置き場: `Packages/FaceCore/Sources/FaceCore/Faces/MergePolicy.swift`
- 問い: この 2 つを、どこまで機械がやってよいか（自動で寄せる／見せる／尋ねる／無視）
- 材料:
  - `similarity` ← 埋め込みのコサイン
  - `bars` ← `FaceTuning` ＋ユーザー校正後のしきい値
    - 約束: ⚠️ **しきい値はモデルの類似度分布に張り付く**。同梱モデルの宣言
      （`face_config.json` の `tuning`）から作る。数値の正本は `face-accuracy.md`
    - テスト: `MergePolicyTests` ＋ データセット計測（`FaceAccuracyEvalTests`）
  - `isFragmentToPerson` ← 小さい方が断片（1〜2 枚・無名・アンカーなし）で相手が確立した人物か
    - 約束: ⚠️⚠️ **人物どうしは、どれだけ似ていても自動で結合しない**（ADR-153）。
      自動は「断片 → 確立した人物」の形のときだけ（失敗の代償が 1 枚外すだけ）
    - テスト: `MergePolicyTests`
- 規則のテスト: `MergePolicyTests`
- ⚠️ 値はすべて**データセット計測で決める**（体感・個別事例では決めない）

---

## AnalysisStallCheck（ADR-87 / 253）

⚠️⚠️ **この項が無かったために、顔の停滞は一度も検出できなかった**（ADR-253）。
台帳の突き合わせが `*Gate` / `*Policy` / `*Turn` の 3 つの名前しか見ていなかったので、
`*Check` という名前のこれだけが**網の外**にあり、材料の約束が誰にも書かれていなかった。
（いまは `*Check` / `*Decision` / `*Plan` も見る。）

- 置き場: `Packages/PerceptionCore/Sources/PerceptionCore/AnalysisStallCheck.swift`
- 問い: 動くべき解析パスが、長期間動いていないか（＝**沈黙そのものを検出する**）
- 材料:
  - `pending`（**`Int?`**）← タグ/埋め込みは `AutoAlbumEngine.analysisProgress()`、
    顔は `PeopleEngine.lastKnownFaceBacklog`
    - 約束: ⚠️⚠️ **0（やることが無い）と nil（分からない）を分けて渡す**。
      `scanProgressRemaining` で埋めない——あれはスキャン中以外 0 なので、
      「分からない」が静かに「終わった」になり、`pending > 0` を入口にしていた
      この検査は**顔について一度も発火しなかった**。顔モデルが無い端末は 0（起こり得ない）。
    - テスト: `FaceBacklogTests`（nil と 0 の区別・前の起動の記録を読む）＋
      `check_forbidden_patterns.py` の `?? scanProgressRemaining` 禁止（見本つき）
  - `lastActivity` ← `AnalysisActivity.lastActivity(_:)`
    - 約束: **1 枚以上処理したときだけ**進む（起こしただけでは進めない）。
      ⚠️ ここが「起こしたとき」に進むと、飢餓しているパスが永久に健全に見える
    - テスト: **未**（`AnalysisActivityTests` は読み書きの往復だけ。宿題に記載）
  - `installedAt` ← `AppSettingsKeys.firstLaunchAt`
    - 約束: 一度も動いていないパスの基準。新規インストール直後に誤検知させない
    - テスト: `AnalysisStallCheckTests`
- 規則のテスト: `AnalysisStallCheckTests`（13 本。ADR-85/86/253 の実バグをシナリオで固定）
- 呼び出し側のテスト: **未**（宿題に記載）
- 効きを見るログ: `analysis STALLED — <pass>(pending=<n|?> idle=<n>d)`
  （⚠️ 分からない残作業は `?` と出す。`0` と書くと「pending=0 なのに停滞」で読めなくなる）

---

## NightlyPlan（ADR-180 / 206 / 222 / 252）
- 置き場: `MosaicPhotos/NightlyWorkPolicy.swift`
- 問い: 処理枠（BGProcessingTask）で**何を・どの順でやるか**
- 材料（すべて `HeavyWorkScheduler.gatherInputs` が測って渡す）:
  - `faceBacklog`（**`Int?`**）← `PeopleEngine.lastKnownFaceBacklog`
    - 約束: ADR-252 と同じ——nil は「分からない」。0 に丸めない
    - テスト: `FaceBacklogTests`
  - `backupReconcileDue` ← `BackupEngine.isReconcileDue()`
    - 約束: ⚠️ **これで手順の位置が変わる**（来ている週だけバックアップの前に出す）
    - テスト: `NightlyPlanTests`
  - `embedBacklog` / `availableMB` / `networkAllowed` / `boostActive` /
    `generateDeferrals` / `provideShareEnabled` / `publishAnalysisEnabled`
    - 約束: `availableMB` は generate のピーク（実測 550〜880MB）と比べる値であること
    - テスト: `NightlyPlanTests`
- 規則のテスト: `NightlyPlanTests`（順序は**実機の失敗が出典**＝窓の食い潰し・
  生成と解析の共倒れ・バックアップの飢餓。変えるときはここを見る）
- 効きを見るログ: 窓の手順ラベル（`analysis` / `generate` / `publishAnalysis` / `backup` …）

---

## TricklePlan（ADR-198 / 85 / 80）
- 置き場: `Packages/AutoAlbumCore/Sources/AutoAlbumCore/Perception/TricklePlan.swift`
- 問い: 背景トリクルで**何を・どの順で・どこまで**やるか（タグ → 埋め込み）
- 材料:
  - `networkAllowed` ← 回線ポリシー（ブーストの免除は `BackgroundYield` の表が答える）
    - 約束: false なら**候補を端末内写真だけに絞る**（クラウドのタグ付けはサムネ DL を伴う）。
      ローカルは通信不要なので常に進む
    - テスト: `TricklePlanTests`
  - `gateOpen` ← 入口の時点でゲートが開いているか
    - 約束: ⚠️ ラベラのウォームは**ゲートの内側だけ**で起こす（ADR-80。外にあったため
      起動直後でも CLIP テキストタワーのロード＝新規インストールで実測 23 秒が走っていた）
    - テスト: `TricklePlanTests`
  - `labelerNeedsWarming` ← 表示ラベラがあり、まだ温まっていないか
    - 約束: ディスクに表があるなら温め直さない（`ConceptEmbeddingCache.hasCachedTable`）
    - テスト: `ConceptTableFingerprintTests`（鍵の方）
- 規則のテスト: `TricklePlanTests`。固定したい不変条件は
  **P1（シーンタグ）に必ず有限の上限がある**こと（無いとタグが窓を独占し埋め込みが永久に飢餓＝ADR-85）と
  **手順は必ず埋め込みで終わる**こと
- 効きを見るログ: `tags(<n>[,local])` / `embed` / `warmLabeler`

---

## 判断ではないもの

ここに並ぶのは「名前は `*Policy` だが、やるかやらないかを決めていない」もの。
⚠️ **理由を 1 行書くこと**——書く手間が「これは判断か？」を一度考えさせる。

<!-- not-gates -->
```
BackgroundPowerPolicy — 利用者の設定の列挙（Int で UserDefaults に保存）。判断は BackgroundYield のゲート表。
BackgroundDataPolicy — 同上（回線の設定の列挙）。
StoreRecoveryPolicy — ストアの種別の札（rebuildable / ledger）。判断は StoreRecoveryAction。
# 入れ子の enum（例: FaceClustering の AmbiguousPolicy）は見ない。判断はトップレベルに出す決め。
```

---

## 残っている宿題

- ~~`CandidateEnumerationGate` の `localCount` が述語を 2 か所に書き写していた~~
  → **済**（`faceScanCandidateFetchOptions(newestFirst:)` が唯一の出典。
  書き写しは `check_forbidden_patterns.py` が止める）。
- ~~`TagWorkGate` に効きが見えるログが無い~~ → **済**（`tags: 重い準備を見送る`。
  `device-verification.md` の一覧にも載せたので、消すと CI が落ちる）。
- `AssetIndexRebuildPolicy` の材料（`lastChangeAt` / `lastRebuildSeconds`）の約束が未テスト。
- `CandidateEnumerationGate` / `TagWorkGate` の**呼び出し側**のテストが無い
  （札を立てる条件を間違えると、残りが永久に処理されない）。
- `AnalysisStallCheck` の `lastActivity` の約束（**1 枚以上処理したときだけ進む**）が未テスト。
  `AnalysisActivityTests` は読み書きの往復しか見ていない。⚠️ ここが「起こしたとき」に
  進む実装に変わると、飢餓しているパスが永久に健全に見える——**沈黙の検出器が沈黙する**
  形（ADR-253 で一度踏んだ）なので、優先度は高い。
- `AnalysisStallCheck` の**呼び出し側**のテストが無い（`logStalledPasses` が顔に
  `lastKnownFaceBacklog` を渡していること。いまは `check_forbidden_patterns.py` の
  禁止規則だけが守っている）。
