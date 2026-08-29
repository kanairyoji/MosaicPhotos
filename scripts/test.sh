#!/usr/bin/env bash
#
# 全パッケージのテストを一括実行する。
#
# テストは2系統に分かれる:
#  1) 高速な純ロジック（Foundation のみ）        → macOS `swift test`
#  2) UIKit / SwiftData / Photos 依存（要 iOS）   → iOS シミュレータ `xcodebuild test`
#
# 使い方:
#   scripts/test.sh            # 全部
#   scripts/test.sh fast       # macOS swift test のみ
#   scripts/test.sh ios        # iOS シミュレータのみ
#   SIM='platform=iOS Simulator,name=iPhone 16' scripts/test.sh   # シミュレータ指定（任意）
#
# ⚠️ シミュレータは**名前で決め打ちしない**。Xcode が上がると古い機種のデバイスは作られなくなり
# （Xcode 26 には iPhone 16 Pro が無い）、`name=…` を固定していると
# 「Unable to find a device matching the provided destination specifier」でジョブごと落ちる。
# 実際 CI がこれで落ちた——テストは 1 つも走っていないのに「テスト失敗」に見える。
# 既定は**その場で使える iPhone を自動で選ぶ**（SIM を明示すればそれを尊重する）。
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-all}"

# macOS で `swift test` を実行する高速パッケージ（純ロジック）。
# LocalPhotoCore はロジック層（旧 LocalPhotoKit のテストを含む）。UI 層 LocalPhotoKit は
# アプリビルド / PhotosFeatureKit 経由でコンパイル検証される。
FAST_PACKAGES=(MosaicSupport PhotoSourceKit ImageCacheKit BackupKit DropboxKit LocalPhotoCore PerceptionCore FaceCore AutoAlbumCore)

# iOS シミュレータでしか走らない（UIKit/SwiftData/Photos 依存テストを含む）パッケージ。
# PhotosFeatureKit は MergedPhotoStore / MergedPhotoItem / PlaceScanner の検証を含む。
IOS_PACKAGES=(DropboxCore PhotosFeatureKit)

run_fast() {
  for pkg in "${FAST_PACKAGES[@]}"; do
    echo "▶ swift test: $pkg (macOS)"
    ( cd "Packages/$pkg" && swift test )
  done
}

# 利用可能な iPhone シミュレータを 1 台選ぶ（新しい iOS 優先・同 iOS なら Pro を優先）。
# 出力: "<UDID> <名前> (<iOS 版>)"。1 台も無ければ空。
pick_simulator() {
  xcrun simctl list devices available -j 2>/dev/null | python3 -c '
import json, re, sys
def version(runtime):
    m = re.search(r"iOS-([0-9-]+)$", runtime)
    return tuple(int(x) for x in m.group(1).split("-")) if m else (0,)
best = None
data = json.load(sys.stdin).get("devices", {})
for runtime, devices in data.items():
    if "iOS" not in runtime: continue
    for d in devices:
        name = d.get("name", "")
        if not name.startswith("iPhone"): continue
        # 新しい iOS を最優先。同 iOS なら Pro（安定して存在する上位機種）を優先。
        key = (version(runtime), 1 if "Pro" in name else 0, name)
        if best is None or key > best[0]:
            best = (key, d.get("udid", ""), name, runtime)
if best:
    print(best[1], best[2], "(" + best[3].split(".")[-1] + ")")
'
}

# CI のシミュレータはコールドブートが遅く（200秒超の回がある）、その間にテストが
# タイムアウトして "TEST FAILED" になるフレークが起きる。テスト前に対象シミュレータを
# 明示的に起動して暖機し、ブート時間をテスト実行時間から切り離す。
boot_sim() {
  local id="$1"
  [ -z "$id" ] && return 0
  xcrun simctl boot "$id" 2>/dev/null || true
  xcrun simctl bootstatus "$id" -b 2>/dev/null || true
}

run_ios() {
  local picked id
  if [ -n "${SIM:-}" ]; then
    echo "▶ simulator (SIM で指定): $SIM"
    id=$(printf '%s' "$SIM" | sed -nE 's/.*id=([0-9A-Fa-f-]{36}).*/\1/p')
  else
    picked=$(pick_simulator)
    if [ -z "$picked" ]; then
      echo "❌ 利用可能な iOS シミュレータが 1 台もありません（Xcode の Platforms を確認）"
      exit 1
    fi
    id=$(printf '%s' "$picked" | awk '{print $1}')
    # ⚠️ 名前ではなく **UDID** で指定する。名前は Xcode の更新で消えることがある。
    SIM="platform=iOS Simulator,id=$id"
    echo "▶ simulator (自動選択): $(printf '%s' "$picked" | cut -d' ' -f2-)  [$id]"
  fi
  boot_sim "$id"
  for pkg in "${IOS_PACKAGES[@]}"; do
    echo "▶ xcodebuild test: $pkg ($SIM)"
    # -retry-tests-on-failure: 遅いシミュレータでのフレークなタイムアウトを吸収（失敗分のみ再試行）。
    # -test-timeouts-enabled: ハングを「名前付きのテスト失敗」に変換する（ジョブ全体の黙り込み防止。
    #   CI ランナーはローカルの数倍遅いことがあるため許容時間は長めに取る）。
    # -resultBundlePath: 失敗時に失敗テスト名を出せるよう xcresult を必ず残す（-quiet はテスト名を
    #   出さないため、これが無いと CI ログから原因テストが特定できない）。
    local bundle=".build/TestResults-$pkg.xcresult"
    if ! ( cd "Packages/$pkg" && rm -rf "$bundle" && xcodebuild test -scheme "$pkg" -destination "$SIM" \
        -retry-tests-on-failure -test-iterations 2 \
        -test-timeouts-enabled YES -default-test-execution-time-allowance 300 \
        -resultBundlePath "$bundle" -quiet ); then
      echo "❌ $pkg: TEST FAILED — 失敗テストの概要:"
      xcrun xcresulttool get test-results summary --path "Packages/$pkg/$bundle" 2>/dev/null \
        | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
    for f in d.get("testFailures", []):
        print("  - " + str(f.get("testName", "?")) + ": " + str(f.get("failureText", ""))[:300])
    print("  (result=" + str(d.get("result")) + ", failedTests=" + str(d.get("failedTests")) + ")")
except Exception as e:
    print("  (xcresult parse failed: " + str(e) + ")")' || true
      exit 1
    fi
  done
}

case "$MODE" in
  fast) run_fast ;;
  ios)  run_ios ;;
  all)  run_fast; run_ios ;;
  *) echo "usage: scripts/test.sh [all|fast|ios]"; exit 2 ;;
esac

echo "✅ All test suites passed."
