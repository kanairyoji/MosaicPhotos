# PeopleKit

このファイルは **Packages/PeopleKit/ を触るときだけ**読み込まれる（Claude Code のディレクトリ単位メモリ）。
root の `CLAUDE.md` には「どのパッケージが何を持つか」だけを置き、
**ファイル単位の詳細はここ**に置く——毎セッション全部を読ませないための分割。

⚠️ 横断的な規約（レイヤー分離・MainActor 既定隔離・記録の必須ルール・性能設計の原則・
i18n・テスト手順）は root の `CLAUDE.md` にある。こちらには**このパッケージ固有のこと**だけ書く。

## ファイル構成

```
Packages/PeopleKit/                ← ピープル（顔クラスタ）の UI 層。FaceCore（ロジック）に依存
  Sources/PeopleKit/
    人物を見る
      AllPeopleView.swift          ピープル一覧（表示フロア・「すべて表示」フィルタ）
      PersonAlbumView.swift        人物アルバム（MergedPhotoStore・顔ハイライト・長押し操作）
      PersonPhotosView.swift       人物の写真グリッド（束ねた全時期）
      PeopleGroupViews.swift       ピープルグループ（家族などの束・ADR-113）

    確認して直す
      FaceReviewView.swift         1 対 1 の確認（はい/いいえ/スキップ・「戻す」は回答ボタンの上）
      FaceBatchReviewView.swift    まとめて確認（0.85 以上は既定でチェック済み・ADR-153）
      FaceReassignPickerView.swift 「この人は別の人」＝付け替え先を選ぶ（共有部品・ADR-137）
      PhotoPersonPickerView.swift  写真から人物を選ぶ（1 人しか写っていない写真の修正）
      PhotoPersonActions.swift     写真ビューの人物操作（長押し・全画面メニューの供給）
      PeopleActions.swift          人物メニュー（改名・代表・顔の管理・束ね）
      PersonCoverPickerView.swift  代表写真を選ぶ
      PersonCleanupView.swift      小さな断片をまとめる（ADR-154）

    調べる（ADR-147）
      PersonInspectorView.swift          状態・読み込み・操作（統合／断片の吸収）
      PersonInspectorView+Sections.swift 画面の各セクション（見た目）
      PersonInspectorView+Labels.swift   数字をユーザー語へ（cos → 似ている度 %）
      InspectorPersonPicker.swift        調査対象の人物を選ぶ
      FaceClusterMembersView.swift       近傍人物の顔一覧（読み取り専用）
      AnswerBasisView.swift              あなたの回答から見た分かれ方（ADR-148）

    部品
      FaceAvatarImage.swift        顔アバター（切り抜き／全体表示の切替・再試行つき）
      FaceGridRows.swift           グリッドを固定列数で行に刻む（⚠️ 下記）
      PeopleImageSupport.swift     refKey → localIdentifier / cloudPath・アバター生成
      PeopleScreenHold.swift       画面表示中は顔スキャンに譲らせる（ADR-142）
      Localization.swift           L(_:)＝Bundle.module 経由のローカライズ
  Tests/PeopleKitTests/            純ロジック（行の刻み方・アバター再試行）＋文字列カタログ
```

## このパッケージ固有の注意

- **`List` の行の中に `LazyVGrid` を置かない**（ADR-161）。SwiftUI の `List` は
  UICollectionView 実装で、行の中の遅延グリッドは高さを決めるたびにレイアウトを無効化する。
  件数が増えると再計算が収束せず、UIKit の assertion で**落ちる**（実機: 「さらに表示」で
  24→48 枚にした直後）。固定列数で自分で行に刻む（`FaceGridRows.chunked`）。
  `ScrollView` の中の `LazyVGrid` は従来どおりで問題ない。
- **「戻す」は「閉じる」から離す**（実フィードバック）。連続で答える画面では、間違いに気づくのは
  答えた直後なので、回答ボタンのすぐ上に文字つきで置く（ツールバーの隅ではなく）。
- **数字はユーザー語にする**（ADR-147）。cos 類似度 → 「似ている度 %」、しきい値 → 「必要な近さ」。
  言い換えは `PersonInspectorView+Labels.swift` に集約し、表記を揺らさない。
- **候補が空のときは理由を出す**（実フィードバック「候補が無いのかバグか分からない」）。
  セクションごと消すと「壊れている」と区別が付かない。
