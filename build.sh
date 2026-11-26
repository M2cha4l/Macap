#!/bin/zsh
# Build standalone Macap.app next to this script (macOS 14.0+ Apple Silicon).
# Resource bundles and the prebuilt 10G UVC helper are embedded inside Contents/Resources,
# so Macap.app can be moved to /Applications or packaged into a .dmg without .build.
set -euo pipefail
cd "$(dirname "$0")"
APP=Macap.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/helper"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleIdentifier</key><string>io.github.m2cha4l.macap</string>
<key>CFBundleName</key><string>Macap</string>
<key>CFBundleDisplayName</key><string>Macap</string>
<key>CFBundleExecutable</key><string>Macap</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.1</string>
<key>CFBundleVersion</key><string>101</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSCameraUsageDescription</key><string>Macap reads the capture card picture to interpolate frames.</string>
<key>NSMicrophoneUsageDescription</key><string>Macap plays the capture card audio.</string>
</dict></plist>
PLIST

swift build -c release
rm -f "$APP/Contents/MacOS/Macap" "$APP/Contents/MacOS/macap-uvc-helper"
cp .build/release/Macap "$APP/Contents/MacOS/Macap"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
find "$APP/Contents/Resources" -maxdepth 1 -name "*.lproj" -exec rm -rf {} +
cp -R Resources/*.lproj "$APP/Contents/Resources/" 2>/dev/null || true

if [[ -f tools/uvc_bulk_helper.c ]]; then
    clang -O2 -mmacosx-version-min=14.0 -Wall -Wextra -Werror tools/uvc_bulk_helper.c \
        -framework IOKit -framework IOSurface -framework CoreFoundation \
        -o "$APP/Contents/Resources/helper/macap-uvc-helper"
    cp tools/install_uvc_helper.sh "$APP/Contents/Resources/helper/install_uvc_helper.sh"
    chmod 0755 "$APP/Contents/Resources/helper/macap-uvc-helper" "$APP/Contents/Resources/helper/install_uvc_helper.sh"
fi

find "$APP/Contents/Resources" -maxdepth 1 -name '*.bundle' -exec rm -rf {} +
cp -R .build/release/*.bundle "$APP/Contents/Resources/"

if [[ "${CLEAN_DIST_BUILD:-0}" == "1" ]]; then
    strip -x "$APP/Contents/MacOS/Macap"
    if [[ -f "$APP/Contents/Resources/helper/macap-uvc-helper" ]]; then
        strip -x "$APP/Contents/Resources/helper/macap-uvc-helper"
    fi
fi

# Distribution mode prefers Developer ID Application if installed, otherwise clean ad-hoc (-).
# Local source builds prefer Apple Development so local camera/mic TCC permissions persist across rebuilds.
if [[ "${CLEAN_DIST_BUILD:-0}" == "1" ]]; then
    DEV_ID=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
    if [[ -n "$DEV_ID" ]]; then
        if [[ -f "$APP/Contents/Resources/helper/macap-uvc-helper" ]]; then
            codesign --force --options runtime --timestamp --sign "$DEV_ID" "$APP/Contents/Resources/helper/macap-uvc-helper"
        fi
        codesign --force --options runtime --timestamp --sign "$DEV_ID" "$APP"
    else
        if [[ -f "$APP/Contents/Resources/helper/macap-uvc-helper" ]]; then
            codesign --force --sign - --timestamp=none "$APP/Contents/Resources/helper/macap-uvc-helper"
        fi
        # Same as local builds: name the bundle id so an update keeps the camera and microphone permission.
        codesign --force --sign - --timestamp=none --requirements '=designated => identifier "io.github.m2cha4l.macap"' "$APP"
    fi
else
    ID=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')
    SIGN_ID="${ID:--}"
    # An ad-hoc signature identifies the app by its hash, which changes on every build, so macOS asks for
    # camera and microphone again. Name the bundle id as the requirement so a rebuild keeps the permission.
    REQ=()
    [[ "$SIGN_ID" == "-" ]] && REQ=(--requirements '=designated => identifier "io.github.m2cha4l.macap"')
    if [[ -f "$APP/Contents/Resources/helper/macap-uvc-helper" ]]; then
        codesign --force --sign "$SIGN_ID" --timestamp=none "$APP/Contents/Resources/helper/macap-uvc-helper"
    fi
    codesign --force --sign "$SIGN_ID" --timestamp=none ${REQ[@]+"${REQ[@]}"} "$APP"
fi

echo "built $APP"
