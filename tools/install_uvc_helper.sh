#!/bin/zsh
# Install (or build + install) the root-owned UVC Bulk helper to /usr/local/libexec/captureinterp-uvc-helper
# with a narrow sudoers NOPASSWD entry limited to that exact binary and its whitelisted flags.
# Works both from a downloaded Maccap.app (using the prebuilt helper in Contents/Resources/helper,
# requiring NO Xcode / Command Line Tools) and from a source checkout (compiling tools/uvc_bulk_helper.c).
#
# Usage:
#   sudo ./tools/install_uvc_helper.sh                      # install for SUDO_USER
#   sudo ./install_uvc_helper.sh --user <desktop_username>  # install when invoked via osascript admin prompt
#   sudo ./tools/install_uvc_helper.sh --uninstall          # remove helper and sudoers rule

set -euo pipefail

DEST_DIR="/usr/local/libexec"
DEST_BIN="$DEST_DIR/captureinterp-uvc-helper"
SUDOERS_FILE="/etc/sudoers.d/captureinterp-uvc-helper"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREBUILT_BIN="$SCRIPT_DIR/captureinterp-uvc-helper"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_C="$SRC_DIR/tools/uvc_bulk_helper.c"
if [[ ! -f "$SRC_C" && -f "$SCRIPT_DIR/uvc_bulk_helper.c" ]]; then
    SRC_C="$SCRIPT_DIR/uvc_bulk_helper.c"
fi

EXPLICIT_USER=""
UNINSTALL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --uninstall)
            UNINSTALL=1
            shift
            ;;
        --user)
            EXPLICIT_USER="${2:-}"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 64
            ;;
    esac
done

if [[ $UNINSTALL -eq 1 ]]; then
    if [[ $EUID -ne 0 ]]; then
        echo "Run with sudo: sudo $0 --uninstall" >&2
        exit 1
    fi
    rm -f "$SUDOERS_FILE" "$DEST_BIN"
    echo "Removed $DEST_BIN and $SUDOERS_FILE"
    exit 0
fi

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo so the helper and directory are owned by root:wheel:" >&2
    echo "  sudo $0" >&2
    exit 1
fi

TARGET_USER="${EXPLICIT_USER:-${SUDO_USER:-}}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    echo "Target desktop user is empty or root; invoke via 'sudo $0' or pass '--user <username>'." >&2
    exit 1
fi
if [[ ! "$TARGET_USER" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Refusing unexpected username: $TARGET_USER" >&2
    exit 1
fi
TARGET_UID="$(/usr/bin/id -u "$TARGET_USER" 2>/dev/null || true)"
if [[ -z "$TARGET_UID" || "$TARGET_UID" == "0" ]]; then
    echo "Refusing unknown or root uid for user: $TARGET_USER" >&2
    exit 1
fi

TMP_BIN="$(/usr/bin/mktemp /tmp/captureinterp-uvc-helper.XXXXXX)"
TMP_SUDOERS="$(/usr/bin/mktemp /tmp/captureinterp-sudoers.XXXXXX)"
trap 'rm -f "$TMP_BIN" "$TMP_SUDOERS"' EXIT

if [[ -x "$PREBUILT_BIN" && "${FORCE_BUILD_HELPER:-0}" != "1" ]]; then
    /bin/cp "$PREBUILT_BIN" "$TMP_BIN"
    /bin/chmod 0755 "$TMP_BIN"
elif [[ -f "$SRC_C" ]]; then
    clang -O2 -mmacosx-version-min=14.0 -Wall -Wextra -Werror "$SRC_C" \
        -framework IOKit -framework IOSurface -framework CoreFoundation \
        -o "$TMP_BIN"
else
    echo "Neither prebuilt helper ($PREBUILT_BIN) nor source ($SRC_C) found." >&2
    exit 1
fi

# Self-test also verifies at runtime via _dyld_image_count that ONLY /System/* and /usr/lib/* dylibs are loaded
"$TMP_BIN" --selftest

for d in /usr/local "$DEST_DIR"; do
    if [[ ! -e "$d" ]]; then
        /usr/bin/install -d -o root -g wheel -m 0755 "$d"
    fi
    if [[ -L "$d" || ! -d "$d" ]]; then
        echo "Refusing symlink or non-directory ancestor: $d" >&2
        exit 1
    fi
    OWNER_UID="$(/usr/bin/stat -f '%u' "$d")"
    PERMS_OCT="$(/usr/bin/stat -f '%Lp' "$d")"
    if [[ "$OWNER_UID" != "0" ]]; then
        echo "Refusing install: $d is owned by uid=$OWNER_UID (must be root:0 so unprivileged users cannot swap $DEST_BIN)" >&2
        exit 1
    fi
    if (( (8#$PERMS_OCT & 8#022) != 0 )); then
        echo "Refusing install: $d is group/world-writable (mode $PERMS_OCT)" >&2
        exit 1
    fi
done

/usr/bin/install -o root -g wheel -m 0755 "$TMP_BIN" "$DEST_BIN"
/usr/bin/codesign --force --sign - --timestamp=none "$DEST_BIN" >/dev/null 2>&1 || true

cat > "$TMP_SUDOERS" <<EOF
# Allow Maccap desktop user to invoke ONLY the root-owned UVC Bulk helper with fixed flags.
Defaults!$DEST_BIN env_reset, !setenv
$TARGET_USER ALL=(root) NOPASSWD: $DEST_BIN "", $DEST_BIN --recover, $DEST_BIN --mode 4k60, $DEST_BIN --mode 4k30, $DEST_BIN --mode 2k60, $DEST_BIN --mode 1080p60
EOF

/bin/chmod 0440 "$TMP_SUDOERS"
/usr/sbin/chown root:wheel "$TMP_SUDOERS"
/usr/sbin/visudo -cf "$TMP_SUDOERS"
/bin/mv "$TMP_SUDOERS" "$SUDOERS_FILE"

echo "Installed $DEST_BIN (root:wheel 0755) and $SUDOERS_FILE for user $TARGET_USER"
