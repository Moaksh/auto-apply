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

# Self-contained: ship the Python engine + the DB contract inside the app. On a tester's Mac the app
# copies them to ~/Library/Application Support/AutoApply/runtime and installs them (uv fetches Python).
REPO="$(cd "$APP_DIR/.." && pwd)"
rsync -a --delete --exclude ".venv" --exclude "__pycache__" --exclude ".pytest_cache" --exclude "tests" \
  "$REPO/engine/autoapply" "$REPO/engine/pyproject.toml" "$REPO/engine/uv.lock" "$REPO/engine/.python-version" \
  "$REPO/engine/README.md" "$OUT/Contents/Resources/engine/"
mkdir -p "$OUT/Contents/Resources/contract" && cp "$REPO/contract/schema.sql" "$OUT/Contents/Resources/contract/"
BUILD_STAMP="$(date +%Y%m%d%H%M%S)"
# One version for the app and the engine it ships: engine/pyproject.toml is the source of truth, and
# the daemon reports autoapply.__version__ (the app restarts a daemon whose version differs from its own).
VERSION="$(sed -nE 's/^version = "([^"]+)"/\1/p' "$REPO/engine/pyproject.toml" | head -1)"
ENGINE_VERSION="$(sed -nE 's/^__version__ = "([^"]+)"/\1/p' "$REPO/engine/autoapply/__init__.py")"
if [ -z "$VERSION" ] || [ "$VERSION" != "$ENGINE_VERSION" ]; then
  echo "Version mismatch: pyproject.toml says '$VERSION', autoapply/__init__.py says '$ENGINE_VERSION'" >&2
  exit 1
fi

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
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_STAMP}</string>
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
