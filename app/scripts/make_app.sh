#!/usr/bin/env bash
# Build app/build/AutoApply.app (release, ad-hoc signed). Usage: app/scripts/make_app.sh
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_DIR"
OUT="$APP_DIR/build/AutoApply.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN/AutoApply" "$OUT/Contents/MacOS/AutoApply"
# SwiftPM resource bundles (if any) live next to the binary.
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$OUT/Contents/Resources/"; done

# Icon (best effort)
ICON_KEY=""
TMP="$(mktemp -d)"
if swift scripts/make_icon.swift "$TMP/icon.png" 2>/dev/null; then
  mkdir "$TMP/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  if iconutil -c icns "$TMP/AppIcon.iconset" -o "$OUT/Contents/Resources/AppIcon.icns"; then
    ICON_KEY='<key>CFBundleIconFile</key><string>AppIcon</string>'
  fi
fi
rm -rf "$TMP"

MIN="$(grep -oE '\.macOS\(\.v[0-9]+\)' Package.swift | head -1 | grep -oE '[0-9]+')"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.autoapply.app</string>
  <key>CFBundleName</key><string>AutoApply</string>
  <key>CFBundleDisplayName</key><string>AutoApply</string>
  <key>CFBundleExecutable</key><string>AutoApply</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>${MIN:-26}.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  ${ICON_KEY}
</dict></plist>
PLIST

codesign --force --deep -s - "$OUT"
echo "Built $OUT"

# Finder / Dock cache icons per bundle path: re-register so a rebuilt icon shows up at once.
touch "$OUT"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$OUT" >/dev/null 2>&1 || true
