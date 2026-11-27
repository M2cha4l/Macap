#!/bin/zsh
# Build a standalone, relocatable, privacy-verified Macap.dmg for Apple Silicon Macs (macOS 14.0+).
#
# Pre-release gates enforced automatically:
#   1. privacy_scan.py --selftest (red-then-green guard verification)
#   2. Clean-room build inside /tmp/macap-dist-XXXXXX so zero /Users/<name> paths enter .build or Mach-O
#   3. Standalone --selftest (plus 4K/2K/1080p hardware benchmark verification) AFTER deleting .build completely
#   4. Full binary + bundle + archive privacy scan on source tree, Macap.app, and final .dmg
#   5. Optional Apple notarization + stapling when Developer ID Application + NOTARY_PROFILE are configured

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${1:-$REPO_ROOT/../Macap-public/dist}"
VERSION=$(sed -n 's|.*<key>CFBundleShortVersionString</key><string>\([^<]*\)</string>.*|\1|p' "$REPO_ROOT/build.sh")   # single source: build.sh
DMG_NAME="Macap-v$VERSION-macOS-arm64.dmg"
DMG_OUT="$DIST_DIR/$DMG_NAME"

echo "==> [1/7] Running privacy guard self-test..."
python3 "$REPO_ROOT/tools/privacy_scan.py" --selftest

WORK_DIR="$(/usr/bin/mktemp -d /tmp/macap-dist.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

CLEAN_SRC="$WORK_DIR/Macap-src"
echo "==> [2/7] Exporting clean source tree into $CLEAN_SRC..."
if [[ -d "$REPO_ROOT/ThirdParty/RifeMetal" && ! -d "$REPO_ROOT/public" ]]; then
    mkdir -p "$CLEAN_SRC"
    # Tracked and new files only: ignored files (build logs, local samples) can hold user paths.
    git -C "$REPO_ROOT" ls-files -z --cached --others --exclude-standard | rsync -a --from0 --files-from=- "$REPO_ROOT/" "$CLEAN_SRC/"
else
    "$REPO_ROOT/tools/make_public.sh" "$CLEAN_SRC"
fi

echo "==> [3/7] Scanning exported source tree for privacy leaks..."
python3 "$REPO_ROOT/tools/privacy_scan.py" "$CLEAN_SRC"

echo "==> [4/7] Building standalone Release Macap.app in clean room..."
(
    cd "$CLEAN_SRC"
    CLEAN_DIST_BUILD=1 ./build.sh
)

APP_PATH="$CLEAN_SRC/Macap.app"

echo "==> [5/7] Deleting .build and verifying 100% standalone execution + hardware tier benchmark..."
rm -rf "$CLEAN_SRC/.build"
CI_BENCH_ALL=1 "$APP_PATH/Contents/MacOS/Macap" --selftest
"$APP_PATH/Contents/Resources/helper/macap-uvc-helper" --selftest

if command -v vtool >/dev/null 2>&1; then
    MIN_OS="$(vtool -show-build "$APP_PATH/Contents/MacOS/Macap" | awk '/minos/{print $2; exit}')"
    if [[ "$MIN_OS" != "14.0" ]]; then
        echo "ERROR: Expected Mach-O minos 14.0, got '${MIN_OS:-unknown}'" >&2
        exit 1
    fi
fi

DEV_ID=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
if [[ -n "$DEV_ID" && -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Submitting Macap.app for Apple notarization (profile: $NOTARY_PROFILE)..."
    NOTARY_ZIP="$WORK_DIR/Macap-notary.zip"
    /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_PATH"
    rm -f "$NOTARY_ZIP"
fi

echo "==> [6/7] Scanning Macap.app for privacy leaks..."
python3 "$REPO_ROOT/tools/privacy_scan.py" "$APP_PATH"

STAGE_DIR="$WORK_DIR/dmg_stage"
mkdir -p "$STAGE_DIR" "$DIST_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/Macap.app"
ln -s /Applications "$STAGE_DIR/Applications"

echo "Macap v$VERSION" > "$STAGE_DIR/使用说明 README.txt"
cat >> "$STAGE_DIR/使用说明 README.txt" <<'TXT'

需要 Apple Silicon Mac（M1 到 M5），macOS 14 或更新。
Requires an Apple Silicon Mac (M1 to M5) with macOS 14 or later.

安装
1. 把 Macap.app 拖进 Applications。
2. 打开 Macap。如果系统说无法验证开发者：点「完成」，打开 系统设置 › 隐私与安全性，点「仍要打开」。
3. 允许摄像头和麦克风权限。

PS5 设置
1. 关闭 HDCP（设定 › 系统 › HDMI）。不关会黑屏。
2. 关闭 HDR、VRR 和 120Hz 输出。
3. 分辨率设为 2160p 或 1080p，60Hz。
4. 声音输出设为线性 PCM。

选档
按 B 测速。约 3 秒后弹窗给出这台 Mac 能稳定运行的设置。

按键
P 设置 · F 全屏 · B 测速 · 1–4 直通/快速/均衡/画质 · X MetalFX · K 锐化 · H 状态条 · Q 退出
语言：菜单栏 Macap › 语言 / Language

Install
1. Drag Macap.app to Applications.
2. Open Macap. If macOS cannot verify the developer, click Done, then System Settings › Privacy & Security › Open Anyway.
3. Allow camera and microphone access.

PS5 settings
1. Turn off HDCP (Settings › System › HDMI). If it is on, the picture is black.
2. Turn off HDR, VRR and 120Hz output.
3. Set the resolution to 2160p or 1080p at 60Hz.
4. Set audio output to Linear PCM.

Press B to benchmark. After about 3 s, a window shows the settings this Mac can hold.
TXT

rm -f "$DMG_OUT"
echo "==> [7/7] Creating compressed disk image $DMG_OUT and running final privacy scan..."
hdiutil create \
    -volname "Macap" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_OUT" >/dev/null

python3 "$REPO_ROOT/tools/privacy_scan.py" "$DMG_OUT"

echo ""
echo "SUCCESS: Standalone universal Apple Silicon release ready:"
ls -lh "$DMG_OUT"
