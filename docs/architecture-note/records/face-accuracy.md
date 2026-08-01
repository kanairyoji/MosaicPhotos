# 顔認識の精度記録（ベンチマーク台帳）

顔認識パイプラインの**精度に関する現状値・パラメーター・計測結果**を集約する台帳。
チューニングの判断は本台帳の**データセット計測**で行う（体感・個別事例では決めない）。
計測方法は ADR-55、パイプラインの経緯は ADR-45〜54 を参照。

## 計測方法

```bash
# データセット取得（FG-NET・初回のみ）
scripts/fetch_face_eval_datasets.sh

# 計測（シミュレータ・実機不要。埋め込みはキャッシュされ2回目以降は数分）
xcodebuild test -project MosaicPhotos.xcodeproj -scheme MosaicPhotos \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:MosaicPhotosTests/FaceAccuracyEvalTests
```

出力は `FACEEVAL:` 行。指標の定義は `FaceEvalMetrics.swift`（B-Cubed / ペア一致 / TAR@FAR）。

## 現行パラメーター（v4 パイプライン）

| パラメーター | 現行値 | 定義場所 |
|---|---|---|
| クラスタリングしきい値（既定） | 0.45 | `FaceStore.clusterThreshold` |
| しきい値校正の可動域 | 0.35〜0.70 | `FaceCalibration.clampRange` |
| 校正の最小サンプル数 | 正負各 8 | `FaceCalibration.minSamples` |
| 品質フロア（未満はクラスタ不参加） | 0.40 | `FaceStore.qualityFloor` |
| 検出信頼度の下限 | 0.80 | `FaceQualityGate.minDetectionConfidence` |
| 最小顔サイズ（正規化比率） | ローカル 0.05 / クラウド 0.15 | `FaceQualityGate.minFaceSide` |
| 最小顔サイズ（絶対ピクセル辺） | 48px | `FaceQualityGate.minFacePixels` |
| 横顔キャップ（\|yaw\|） | ≥30° → 品質 0.2 | `FaceQualityGate.yawLimit/profileCap` |
| 傾きキャップ（\|roll\|） | ≥45° → 品質 0.2 | `FaceQualityGate.rollLimit` |
| 目閉じ減衰 | ×0.6 | `FaceQualityGate.eyesClosedFactor` |
| ぼけ（ラプラシアン分散・64px 基準） | <25 キャップ / <60 ×0.7 | `FaceQualityGate.blurHardFloor/blurSoftFloor` |
| 露出（平均輝度） | <20 or >235 キャップ / <40 or >215 ×0.6 | `FaceQualityGate.luma*` |
| クロップ再検証の最小占有 | 幅 25% | `FaceQualityGate.cropVerifyMinSide` |
| 埋め込み | facenet InceptionResnetV1/VGGFace2・512 次元・アライメント＋マルチクロップ 3 平均 | `FacePerceptionAdapter` |
| 処理解像度 | ローカル 1024px / クラウドはキャッシュサムネ | 同上 |
| 共起 notSame | 同一写真 3 回以上で別人扱い | `FaceStore.coOccurrenceNotSame` |
| パイプライン版数 | v4 | `PeopleEngine.faceScanVersion` |

## 計測ログ

### 2026-08-01 — v4 ベースライン（FG-NET・1,002 枚・82 人・0〜69 歳）

**検出（顔を見つける）: 良好**
- 顔採用率: **99.6%**（998/1002）。年齢別: 0-2歳 98% / 3-5歳 100% / 6-12歳 100% / 13-19歳 100% / 20歳+ 100%
- ゲートによる正当な顔の過剰棄却は無し

**識別（同一人物と分かる）: 弱い（現状の主課題）**
- 検証: 同一ペア平均類似度 0.550 / 別人ペア 0.151・**TAR@FAR1% = 48.1%**・TAR@FAR0.1% = 24.3%・最良 F1 しきい値 0.64
- 同一人物の年齢差別 平均類似度: **0-2年 0.718 / 3-5年 0.661 / 6-10年 0.558 / 11-20年 0.440 / 21年+ 0.400**
  （年齢差 10 年超で現行しきい値 0.45 を平均が下回る＝成長期分裂の定量確認）
- 別人×両者 12 歳以下（兄弟の代理）: 平均 0.294

**クラスタリングしきい値スイープ（B-Cubed）**

| thr | 精度 P | 再現率 R | F1 | ペア F1 | クラスタ数 |
|---|---|---|---|---|---|
| 0.35 | 0.249 | 0.485 | 0.329 | 0.096 | 112 |
| 0.40 | 0.299 | 0.466 | 0.364 | 0.106 | 124 |
| **0.45（現行）** | 0.420 | 0.472 | **0.444** | 0.163 | 144 |
| 0.50 | 0.528 | 0.474 | 0.500 | 0.190 | 169 |
| 0.55 | 0.610 | 0.468 | 0.530 | 0.258 | 196 |
| **0.60** | 0.721 | 0.435 | **0.542** | 0.296 | 248 |
| 0.65 | 0.822 | 0.399 | 0.538 | 0.365 | 322 |
| 0.70 | 0.907 | 0.342 | 0.497 | 0.360 | 416 |

**未計測**: 偽陽性率（顔でないものを顔とする率）。FG-NET に顔なし画像が無いため、
ネガティブセット（風景等）の追加が必要。

## 運用ルール

- パイプライン・パラメーター変更時は本ハーネスで**変更前後を計測**し、この台帳に追記する。
- 判断はデータセット計測で行う（自前写真はデータセットに入れない方針）。
- FG-NET は相対比較用（モデル間・変更前後）。絶対値は分布差があることに留意。
