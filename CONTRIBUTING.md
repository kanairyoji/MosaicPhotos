# MosaicPhotos へのコントリビュート

> このドキュメントの正本は**日本語**です。末尾に参考用の英訳（English）を付けます。

ご関心ありがとうございます。

## コントリビュートのライセンス（DCO ＋ 再ライセンス許諾）

ソースコードは **AGPL-3.0-or-later** で配布しています。デュアル配布（AGPL での
オープンソース公開と、著作権者による App Store 向けビルドの Apple 条件での配布）を
維持するため、コントリビュートは次の条件で受け付けます。

1. **DCO（Developer Certificate of Origin）**：各コミットに
   `Signed-off-by: 氏名 <メール>` を付けてください（`git commit -s`）。これは、その変更を
   あなたが作成した、またはプロジェクトのライセンスのもとで提出する権利があることの表明です
   （https://developercertificate.org/）。

2. **再ライセンス許諾**：コントリビュートを提出することにより、著作権者
   （Ryoji KANAI \<kanai@r89.org\>）が、あなたの貢献を AGPL-3.0-or-later のもとで
   ライセンスできること、**および**それを他の条件（例：App Store 向けビルド）でも配布できる
   ことに同意するものとします（＝メンテナによる再ライセンスを許諾）。

これらに同意できない場合は、プルリクエスト送付前に Issue でご相談ください。

## 開発

- ビルド／テストの手順は `README.md` と `CLAUDE.md`（`scripts/test.sh`）を参照。
- 重要な設計判断・事例は `docs/architecture-note/records/*.md` に記録してください（CLAUDE.md 参照）。

### Claude Code スキル（任意・AI 支援開発を行う場合）

本リポジトリは AI コーディング支援（Claude Code）を併用して開発しています。スキルは
`~/.claude/skills/` に置かれ**リポジトリ外**（`.claude/` は `.gitignore` 対象）なので、
再現するには各自で導入が必要です。必須ではありません。

導入しているのは [dpearson2699/swift-ios-skills](https://github.com/dpearson2699/swift-ios-skills)
の `ios-ai-ml-skills` バンドル（Apple の Core ML / Vision / Foundation Models 等の
リファレンス）で、本プロジェクトのオンデバイス AI（`MobileCLIPKit` / `FaceCore` /
`PerceptionCore`）に対応します。

```
/plugin marketplace add dpearson2699/swift-ios-skills
/plugin install ios-ai-ml-skills@swift-ios-skills
```

`/plugin install` が無反応の場合は、マーケットプレイスの clone から直接コピーしても同じです：

```bash
src=~/.claude/plugins/marketplaces/swift-ios-skills/skills
for s in apple-on-device-ai coreml natural-language speech-recognition vision-framework; do
  cp -R "$src/$s" ~/.claude/skills/"$s"
done
```

⚠️ これらのスキルは**一般論**であり、本プロジェクトの決定と矛盾する箇所があります
（`CLAUDE.md` の「外部スキルとの優先順位」を参照）。矛盾時はプロジェクトの決定が優先します。

------------------------------------------------------------------------------
## English (reference translation; the Japanese above is the master)

The source code is licensed under **AGPL-3.0-or-later**. To keep dual distribution
possible (open source under the AGPL, plus the maintainer's App Store build under
Apple's terms), contributions are accepted under:

1. **Developer Certificate of Origin (DCO):** sign off each commit with
   `Signed-off-by: Your Name <email>` (`git commit -s`), certifying you may submit
   the change under the project license (https://developercertificate.org/).

2. **Relicensing grant:** by submitting a contribution, you agree that the copyright
   holder (Ryoji KANAI \<kanai@r89.org\>) may license your contribution under
   AGPL-3.0-or-later **and** may also distribute it under other terms (e.g., the
   App Store build).

If you cannot agree, please open an issue before sending a pull request.
