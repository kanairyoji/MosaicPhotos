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

run_ios() {
  for pkg in "${IOS_PACKAGES[@]}"; do
    echo "▶ xcodebuild test: $pkg ($SIM)"
    ( cd "Packages/$pkg" && xcodebuild test -scheme "$pkg" -destination "$SIM" -quiet )
  done
}

case "$MODE" in
  fast) run_fast ;;
  ios)  run_ios ;;
  all)  run_fast; run_ios ;;
  *) echo "usage: scripts/test.sh [all|fast|ios]"; exit 2 ;;
esac

echo "✅ All test suites passed."
