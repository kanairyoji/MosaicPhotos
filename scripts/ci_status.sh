#!/usr/bin/env bash
# コミットの CI を**ジョブ単位で**見る。
#
# ⚠️ なぜ要るか: CI の iOS ジョブは `continue-on-error: true`（非ブロッキング）なので、
# そのジョブが落ちても **run 全体の結論は success のまま**になる。`gh run list` の
# conclusion だけを見て「CI 緑」と報告する誤りを 2 回やった（2026-09-29 と、v1.17 の
# 0edc7fc）。2 回目は 1 回目の教訓がワークフローのコメントに書いてあったのに起きた。
#
# 使い方:
#   scripts/ci_status.sh            # HEAD
#   scripts/ci_status.sh <sha>
#
# 終了コード: 失敗・取り消し・未完了のジョブが 1 つでもあれば 1（全部 success/skipped なら 0）。
set -euo pipefail

sha=$(git rev-parse "${1:-HEAD}")
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

lines=$(gh api "repos/$repo/commits/$sha/check-runs" --paginate \
  --jq '.check_runs[] | "\(.conclusion // .status)\t\(.name)"')
if [ -z "$lines" ]; then
  echo "⚠️ ${sha:0:7}: ジョブが 1 つも無い（まだ始まっていないか、push されていない）"
  exit 1
fi

echo "${sha:0:7} のジョブ:"
printf '%s\n' "$lines" | sort | sed 's/^/  /'

bad=$(printf '%s\n' "$lines" | awk -F'\t' '$1 != "success" && $1 != "skipped" && $1 != "neutral"' || true)
if [ -n "$bad" ]; then
  echo ""
  echo "❌ 緑ではないジョブがある（run 全体が success でも、これは失敗）:"
  printf '%s\n' "$bad" | sed 's/^/  /'
  exit 1
fi
echo "✅ 全ジョブ success"
