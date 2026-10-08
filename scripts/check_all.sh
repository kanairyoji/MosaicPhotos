#!/bin/bash
# CI の検査スクリプトを**列挙して**全部回す（ADR-265）。
#
# ⚠️ なぜ要るか（2026-10-08・2 回踏んだ）
# 報告のたびに「ガード N 本 green」と手で数えていたら、**4 本と数えて 5 本目を落とした**。
# 落ちたのは `check_removed_symbols.py` で、**引数を取る**ため引数なしのループから
# 静かに外れていた。1 回目はそれが**実際の失敗を隠した**——`19d9d21` の時点で
# この検査は落ちていたのに「3 本 green」と報告し、改名で残った古いコメントを見逃した。
#
# 数は手で数えない。`scripts/check_*.py` を列挙する。
#
# ⚠️⚠️ あわせて **CI に配線されていない検査**も見つける。検査を足しても
# `ci.yml` に書かなければ一度も走らない——「表に無いものは視界に入らない」
# （ADR-259）と同じ形で、しかも「検査を足した」という満足だけが残るので危ない。
#
# 使い方:
#   scripts/check_all.sh            # 比較元は origin/main
#   scripts/check_all.sh <base>     # 比較元を指定（例: push 前の先端）
set -uo pipefail
cd "$(dirname "$0")/.."

BASE="${1:-origin/main}"
CI_FILE=".github/workflows/ci.yml"
failed=0
ran=0
# ⚠️ 配列ではなく文字列に溜める（macOS 既定の bash 3.2 は `set -u` 下で
#    空配列を「未定義」として扱い、`${#arr[@]}` でスクリプトが落ちる）。
unwired=""

for script in scripts/check_*.py; do
  name="$(basename "$script")"
  # CI に配線されているか（配線漏れは「足したのに一度も走らない」）。
  if ! grep -q "scripts/$name" "$CI_FILE"; then
    unwired="$unwired $name"
  fi
  # ⚠️ 引数が要る検査を**特別扱いで落とさない**。要るものだけ渡す。
  if grep -q "sys.argv" "$script"; then
    out="$(python3 "$script" "$BASE" 2>&1)"
  else
    out="$(python3 "$script" 2>&1)"
  fi
  if [ $? -eq 0 ]; then
    echo "✅ $name"
  else
    echo "❌ $name"
    echo "$out" | sed 's/^/     /'
    failed=1
  fi
  ran=$((ran + 1))
done

if [ -n "$unwired" ]; then
  echo
  echo "❌ CI に配線されていない検査があります（足しても一度も走りません）:"
  for name in $unwired; do echo "   $name"; done
  echo "   → $CI_FILE にステップを足してください。"
  failed=1
fi

echo
if [ $failed -eq 0 ]; then
  echo "✅ 検査 $ran 本すべて green（比較元 ${BASE}・CI への配線も確認）"
else
  echo "❌ 検査 $ran 本のうち失敗あり"
fi
exit $failed
