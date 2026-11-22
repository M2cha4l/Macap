#!/bin/zsh
# Build a standalone, relocatable, privacy-verified Maccap.dmg for Apple Silicon Macs (macOS 14.0+).
#
# Pre-release gates enforced automatically:
#   1. privacy_scan.py --selftest (red-then-green guard verification)
#   2. Clean-room build inside /tmp/captureinterp-dist-XXXXXX so zero /Users/<name> paths enter .build or Mach-O
#   3. Standalone --selftest (plus 4K/2K/1080p hardware benchmark verification) AFTER deleting .build completely
#   4. Full binary + bundle + archive privacy scan on source tree, Maccap.app, and final .dmg
#   5. Optional Apple notarization + stapling when Developer ID Application + NOTARY_PROFILE are configured

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${1:-$REPO_ROOT/../Maccap-public/dist}"
DMG_NAME="Maccap-v1.0.0-macOS-arm64.dmg"
DMG_OUT="$DIST_DIR/$DMG_NAME"

echo "==> [1/7] Running privacy guard self-test..."
python3 "$REPO_ROOT/tools/privacy_scan.py" --selftest

WORK_DIR="$(/usr/bin/mktemp -d /tmp/captureinterp-dist.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

CLEAN_SRC="$WORK_DIR/Maccap-src"
echo "==> [2/7] Exporting clean source tree into $CLEAN_SRC..."
if [[ -d "$REPO_ROOT/ThirdParty/RifeMetal" && ! -d "$REPO_ROOT/public" ]]; then
    mkdir -p "$CLEAN_SRC"
    rsync -a --exclude '.git' --exclude '.build' --exclude 'dist' --exclude '*.app' --exclude '*.dmg' --exclude '.DS_Store' "$REPO_ROOT/" "$CLEAN_SRC/"
else
    "$REPO_ROOT/tools/make_public.sh" "$CLEAN_SRC"
fi

echo "==> [3/7] Scanning exported source tree for privacy leaks..."
python3 "$REPO_ROOT/tools/privacy_scan.py" "$CLEAN_SRC"

echo "==> [4/7] Building standalone Release Maccap.app in clean room..."
(
    cd "$CLEAN_SRC"
    CLEAN_DIST_BUILD=1 ./build.sh
)

APP_PATH="$CLEAN_SRC/Maccap.app"

echo "==> [5/7] Deleting .build and verifying 100% standalone execution + hardware tier benchmark..."
rm -rf "$CLEAN_SRC/.build"
CI_BENCH_ALL=1 "$APP_PATH/Contents/MacOS/Maccap" --selftest
"$APP_PATH/Contents/Resources/helper/captureinterp-uvc-helper" --selftest

if command -v vtool >/dev/null 2>&1; then
    MIN_OS="$(vtool -show-build "$APP_PATH/Contents/MacOS/Maccap" | awk '/minos/{print $2; exit}')"
    if [[ "$MIN_OS" != "14.0" ]]; then
        echo "ERROR: Expected Mach-O minos 14.0, got '${MIN_OS:-unknown}'" >&2
        exit 1
    fi
fi

DEV_ID=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
if [[ -n "$DEV_ID" && -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Submitting Maccap.app for Apple notarization (profile: $NOTARY_PROFILE)..."
    NOTARY_ZIP="$WORK_DIR/Maccap-notary.zip"
    /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_PATH"
    rm -f "$NOTARY_ZIP"
fi

echo "==> [6/7] Scanning Maccap.app for privacy leaks..."
python3 "$REPO_ROOT/tools/privacy_scan.py" "$APP_PATH"

STAGE_DIR="$WORK_DIR/dmg_stage"
mkdir -p "$STAGE_DIR" "$DIST_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/Maccap.app"
ln -s /Applications "$STAGE_DIR/Applications"

cat > "$STAGE_DIR/使用说明（PS5必读）.txt" <<'TXT'
Maccap v1.0.0
适用电脑：搭载 Apple Silicon（M1 / M2 / M3 / M4 / M5 全系芯片）的 Mac，系统 macOS 14.0 或更新（不支持老款 Intel Mac）

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【一、安装与首次打开】
1. 把「Maccap.app」拖进右侧「Applications（应用程序）」文件夹。
2. 首次打开若提示“未验证开发者”：
   - 在「应用程序」中按住 Control 键（或点鼠标右键）点击 Maccap.app → 选择「打开」；
   - 若系统仍拦截，打开「系统设置 → 隐私与安全性」，拉到底部点击「仍要打开」（仅首次需要）。
3. 首次运行请允许「摄像头」和「麦克风」权限（免驱 HDMI 采集卡在 macOS 中识别为外接摄像头与麦克风）。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【二、PS5 主机端必改设置（避免黑屏或偏色）】
1. 关闭 HDCP（系统 → HDMI → 启用 HDCP：关，不关会黑屏）
2. 关闭 HDR、关闭 VRR、关闭 120Hz 输出
3. 分辨率设为 2160p（4K）或 1080p，60Hz
4. 声音输出设为「2 声道线性 PCM（Linear PCM）」

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【三、我的苹果电脑带得动哪一档？（3 秒一键实测）】
★ 最准方法：打开软件后【点鼠标右键】或按【B 键】，点击第一项：
  「⚡ 一键测算本机接 PS5 推荐档位 (B)…」
  程序会花 3 秒实测你这台电脑跑 4K / 2K / 1080p 的真实耗时，弹窗直接给出最佳档位并支持一键应用！

机型速查参考（除 M5 Max 40 核显卡为实测外，其余按显卡规模比例换算·推算未核实，以软件内按 B 键实测为准）：
· M4 Max / M5 Max / Ultra（32–80核显卡）：4K 原生 ＋ [5] 显卡·画质好（或 [6] 4.5档低延迟）
· M1 Max / M2 Max / M3 Max（24–40核显卡）：4K 原生 ＋ [6] 显卡·均衡 4.5 档（重场景可切 4K [4] 或 2K [5]）
· M4 Pro / M5 Pro（16–20核显卡）        ：4K 原生 ＋ [4] 延迟低，或 限制 2K ＋ [6] 均衡 4.5 档
· M1 Pro / M2 Pro / M3 Pro（14–19核显卡）：限制 2K ＋ [6] 均衡 4.5 档
· M3 / M4 / M5 基础版（带风扇 Mac mini 等）：限制 2K ＋ [4] 延迟低，或 限制 1080p ＋ [6] 均衡 4.5 档
· M1 / M2 基础版 & 全系 MacBook Air（无风扇）：限制 1080p ＋ [6] 均衡 4.5 档 / [4] 延迟低（防长玩发热降频）

（换算底数参考：M5 Max 40核实测 4K 耗时 6.0 / 11.1 / 23.3 毫秒；降到 2K 耗时直接砍半还多，降到 1080p 耗时只剩不到 1/4。单张 ≤ 25.5 毫秒即可稳跑 60 帧不掉帧。）

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【四、图形控制面板与常用快捷键】
- 打开软件默认以桌面窗口启动，中央直接显示可视化控制面板（连接 PS5 采集卡后自动收起进入画面）
- P 键 / 右上角按钮：随时打开或收起图形控制面板（所有设置自动记忆）
- F 键 / 双击画面：切换「桌面窗口模式 ⇄ 无边框全屏游玩」（全屏下按 Esc 退回窗口）
- B 键：一键实测本机芯片推荐档位
- 数字键 1–6：切换补帧档位（玩原生 60 帧游戏请按 1 切直通）
- K 键：切换自适应锐化强度（关 / 标准 0.55 / 强 0.90）
- U 键：切换 USB 256KB 无损直读（10Gbps 0bda:0911 采集卡可在面板一键授权安装组件，免终端免 Xcode）
- H 键：常显实时帧率与等待延迟状态条
- Q 键 / ⌘Q：退出软件
TXT

rm -f "$DMG_OUT"
echo "==> [7/7] Creating compressed disk image $DMG_OUT and running final privacy scan..."
hdiutil create \
    -volname "Maccap" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_OUT" >/dev/null

python3 "$REPO_ROOT/tools/privacy_scan.py" "$DMG_OUT"

echo ""
echo "SUCCESS: Standalone universal Apple Silicon release ready:"
ls -lh "$DMG_OUT"
