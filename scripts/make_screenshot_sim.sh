#!/bin/bash
# ドキュメント用スクリーンショット専用のシミュレータを構築する。
#
# - **使い捨ての新規シミュレータ**を作る（既存の開発用シミュレータには一切触れない）。
# - 写真ライブラリにはフリーライセンス素材（scripts/fetch_screenshot_photos.sh）だけを
#   入れるので、このシミュレータの画面はスクリーンショットにしてよい（個人写真ゼロ）。
# - 事前に: fetch_screenshot_photos.sh → swift scripts/inject_screenshot_exif.swift を実行し、
#   アプリを iphonesimulator 向けにビルドしておく。
#
# 使い方: scripts/make_screenshot_sim.sh
# 撮影:   xcrun simctl io "MosaicShots" screenshot shot.png
set -euo pipefail

cd "$(dirname "$0")/.."
NAME="MosaicShots"
BUNDLE="com.kanai.MosaicPhotos"
ASSETS=.screenshot_assets/tagged

if [[ ! -d "$ASSETS" || -z "$(ls "$ASSETS" 2>/dev/null)" ]]; then
  echo "no tagged assets — run fetch_screenshot_photos.sh + inject_screenshot_exif.swift first"
  exit 1
fi

# 1. 専用シミュレータ（既存なら再利用・無ければ作成）
UDID=$(xcrun simctl list devices | grep "$NAME (" | grep -oE "[0-9A-F-]{36}" | head -1 || true)
if [[ -z "$UDID" ]]; then
  RUNTIME=$(xcrun simctl list runtimes | grep -oE "com.apple.CoreSimulator.SimRuntime.iOS[0-9-]+" | tail -1)
  UDID=$(xcrun simctl create "$NAME" "iPhone 17 Pro" "$RUNTIME")
  echo "created $NAME ($UDID)"
else
  echo "reusing $NAME ($UDID)"
fi

xcrun simctl bootstatus "$UDID" -b

# 2. 素材を写真ライブラリへ投入
echo "adding $(ls "$ASSETS" | wc -l | tr -d ' ') photos…"
xcrun simctl addmedia "$UDID" "$ASSETS"/*.jpg

# 3. アプリをインストール・起動
APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*Debug-iphonesimulator/MosaicPhotos.app" -newer MosaicPhotos.xcodeproj/project.pbxproj 2>/dev/null | head -1)
if [[ -z "$APP" ]]; then
  APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*Debug-iphonesimulator/MosaicPhotos.app" 2>/dev/null | head -1)
fi
if [[ -z "$APP" ]]; then
  echo "MosaicPhotos.app not found — build for iphonesimulator first"
  exit 1
fi
xcrun simctl install "$UDID" "$APP"
# ⚠️ `simctl privacy grant photos` は iOS 26 ランタイムでは効かないどころか、
# 「決定済み（拒否）」状態を作ってダイアログすら出なくなる。写真アクセスの許可は
# UITest（ScreenshotCaptureTests がダイアログをタップ）に一本化する。
xcrun simctl privacy "$UDID" reset photos "$BUNDLE" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE"
echo
echo "ready: $NAME ($UDID)"
echo "  screenshot: xcrun simctl io $UDID screenshot shot.png"
echo "  cleanup:    xcrun simctl delete $UDID   # 使い捨て・いつ消してもよい"
