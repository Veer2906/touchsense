#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product TapSense
APP="${TAPSENSE_APP_DIR:-$HOME/Library/Caches/local.tapsense}/TapSense.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/TapSense" "$APP/Contents/MacOS/TapSense"
cp App/Info.plist "$APP/Contents/Info.plist"
cp -R App/ui "$APP/Contents/Resources/ui"
xattr -cr "$APP"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
if [ "${CODESIGN_IDENTITY:--}" = "-" ]; then
  tccutil reset Accessibility local.tapsense >/dev/null 2>&1 || true
  tccutil reset ScreenCapture local.tapsense >/dev/null 2>&1 || true
fi
echo "$APP"
