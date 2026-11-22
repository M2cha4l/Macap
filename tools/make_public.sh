#!/bin/zsh
# Assemble the clean public source tree (no development history, no machine-specific paths).
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$SRC/../Maccap-public}"
RIFE="${RIFE_RUNTIME:-$HOME/Developer/OpenDuckFrame/ThirdParty/rife-metal/runtime}"

rm -rf "$OUT"
mkdir -p "$OUT/ThirdParty" "$OUT/tools"

cp "$SRC/main.swift" "$OUT/main.swift"
cp "$SRC/tools/scprobe.swift" \
   "$SRC/tools/uvc_bulk_helper.c" \
   "$SRC/tools/install_uvc_helper.sh" \
   "$SRC/tools/privacy_scan.py" \
   "$SRC/tools/package_dmg.sh" \
   "$OUT/tools/"
chmod +x "$OUT/tools/install_uvc_helper.sh" "$OUT/tools/privacy_scan.py" "$OUT/tools/package_dmg.sh"

cp "$SRC/public/README.md" \
   "$SRC/public/LICENSE" \
   "$SRC/public/THIRD_PARTY_NOTICES.md" \
   "$SRC/public/Package.swift" \
   "$SRC/public/build.sh" \
   "$SRC/public/.gitignore" \
   "$OUT/"
chmod +x "$OUT/build.sh"

rsync -a \
    --exclude '.git' \
    --exclude '.build' \
    --exclude '.swiftpm' \
    --exclude '.DS_Store' \
    --exclude '*.orig_bak' \
    --exclude '*.bak' \
    "$RIFE/" "$OUT/ThirdParty/RifeMetal/"

echo "public tree: $OUT"
