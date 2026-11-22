#!/bin/zsh
# Build standalone CaptureInterp.app next to this script (macOS 14.0+ Apple Silicon).
# Resource bundles and the prebuilt 10G UVC helper are embedded inside Contents/Resources,
# so CaptureInterp.app can be moved to /Applications or packaged into a .dmg without .build.
set -euo pipefail
cd "$(dirname "$0")"
APP=CaptureInterp.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/helper"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.captureinterp.app</string>
<key>CFBundleName</key><string>CaptureInterp</string>
<key>CFBundleDisplayName</key><string>CaptureInterp</string>
<key>CFBundleExecutable</key><string>CaptureInterp</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>100</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSCameraUsageDescription</key><string>读取采集卡或摄像头的画面用于实时补帧。Reads the capture card picture for frame interpolation.</string>
<key>NSMicrophoneUsageDescription</key><string>播放采集卡送入的声音并与画面同步。Plays the capture card audio synchronized with the picture.</string>
</dict></plist>
PLIST

swift build -c release
rm -f "$APP/Contents/MacOS/CaptureInterp" "$APP/Contents/MacOS/captureinterp-uvc-helper"
cp .build/release/CaptureInterp "$APP/Contents/MacOS/CaptureInterp"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ -f tools/uvc_bulk_helper.c ]]; then
    clang -O2 -mmacosx-version-min=14.0 -Wall -Wextra -Werror tools/uvc_bulk_helper.c \
        -framework IOKit -framework IOSurface -framework CoreFoundation \
        -o "$APP/Contents/Resources/helper/captureinterp-uvc-helper"
    cp tools/install_uvc_helper.sh "$APP/Contents/Resources/helper/install_uvc_helper.sh"
    chmod 0755 "$APP/Contents/Resources/helper/captureinterp-uvc-helper" "$APP/Contents/Resources/helper/install_uvc_helper.sh"
fi

find "$APP/Contents/Resources" -maxdepth 1 -name '*.bundle' -exec rm -rf {} +
cp -R .build/release/*.bundle "$APP/Contents/Resources/"

if [[ "${CLEAN_DIST_BUILD:-0}" == "1" ]]; then
    strip -x "$APP/Contents/MacOS/CaptureInterp"
    if [[ -f "$APP/Contents/Resources/helper/captureinterp-uvc-helper" ]]; then
        strip -x "$APP/Contents/Resources/helper/captureinterp-uvc-helper"
    fi
fi

# Distribution mode prefers Developer ID Application if installed, otherwise clean ad-hoc (-).
# Local source builds prefer Apple Development so local camera/mic TCC permissions persist across rebuilds.
if [[ "${CLEAN_DIST_BUILD:-0}" == "1" ]]; then
    DEV_ID=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
    if [[ -n "$DEV_ID" ]]; then
        if [[ -f "$APP/Contents/Resources/helper/captureinterp-uvc-helper" ]]; then
            codesign --force --options runtime --timestamp --sign "$DEV_ID" "$APP/Contents/Resources/helper/captureinterp-uvc-helper"
        fi
        codesign --force --options runtime --timestamp --sign "$DEV_ID" "$APP"
    else
        if [[ -f "$APP/Contents/Resources/helper/captureinterp-uvc-helper" ]]; then
            codesign --force --sign - --timestamp=none "$APP/Contents/Resources/helper/captureinterp-uvc-helper"
        fi
        codesign --force --sign - --timestamp=none "$APP"
    fi
else
    ID=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')
    SIGN_ID="${ID:--}"
    if [[ -f "$APP/Contents/Resources/helper/captureinterp-uvc-helper" ]]; then
        codesign --force --sign "$SIGN_ID" --timestamp=none "$APP/Contents/Resources/helper/captureinterp-uvc-helper"
    fi
    codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
fi

echo "built $APP"
