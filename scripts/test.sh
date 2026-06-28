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
#   SIM='platform=iOS Simulator,name=iPhone 16' scripts/test.sh   # シミュレータ指定
#
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-all}"
SIM="${SIM:-platform=iOS Simulator,name=iPhone 17 Pro}"

# macOS で `swift test` を実行する高速パッケージ（純ロジック）。
# LocalPhotoCore はロジック層（旧 LocalPhotoKit のテストを含む）。UI 層 LocalPhotoKit は
# アプリビルド / PhotosFeatureKit 経由でコンパイル検証される。
FAST_PACKAGES=(MosaicSupport PhotoSourceKit ImageCacheKit BackupKit DropboxKit LocalPhotoCore AutoAlbumCore)

# iOS シミュレータでしか走らない（UIKit/SwiftData/Photos 依存テストを含む）パッケージ。
# PhotosFeatureKit は MergedPhotoStore / MergedPhotoItem / PlaceScanner の検証を含む。
IOS_PACKAGES=(DropboxCore PhotosFeatureKit)

run_fast() {
  for pkg in "${FAST_PACKAGES[@]}"; do
    echo "▶ swift test: $pkg (macOS)"
    ( cd "Packages/$pkg" && swift test )
  done
}

# CI のシミュレータはコールドブートが遅く（200秒超の回がある）、その間にテストが
# タイムアウトして "TEST FAILED" になるフレークが起きる。テスト前に対象シミュレータを
# 明示的に起動して暖機し、ブート時間をテスト実行時間から切り離す。
boot_sim() {
  local name id
  name=$(printf '%s' "$SIM" | sed -nE 's/.*name=([^,]+).*/\1/p')
  [ -z "$name" ] && return 0
  id=$(xcrun simctl list devices available 2>/dev/null | grep -F "$name (" | head -1 | grep -oE '[0-9A-Fa-f-]{36}' || true)
  [ -z "$id" ] && return 0
  echo "▶ booting simulator: $name ($id)"
  xcrun simctl boot "$id" 2>/dev/null || true
  xcrun simctl bootstatus "$id" -b 2>/dev/null || true
}

run_ios() {
  boot_sim
  for pkg in "${IOS_PACKAGES[@]}"; do
    echo "▶ xcodebuild test: $pkg ($SIM)"
    # -retry-tests-on-failure: 遅いシミュレータでのフレークなタイムアウトを吸収（失敗分のみ再試行）。
    ( cd "Packages/$pkg" && xcodebuild test -scheme "$pkg" -destination "$SIM" \
        -retry-tests-on-failure -test-iterations 2 -quiet )
  done
}

case "$MODE" in
  fast) run_fast ;;
  ios)  run_ios ;;
  all)  run_fast; run_ios ;;
  *) echo "usage: scripts/test.sh [all|fast|ios]"; exit 2 ;;
esac

echo "✅ All test suites passed."
