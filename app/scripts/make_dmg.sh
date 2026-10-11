#!/usr/bin/env bash
# Build app/build/AutoApply-<version>.dmg (drag-to-Applications). Usage: app/scripts/make_dmg.sh
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$APP_DIR/scripts/make_app.sh"
APP="$APP_DIR/build/AutoApply.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
STAGE="$(mktemp -d)/AutoApply"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
AutoApply (beta) — install

1. Drag AutoApply into Applications.
2. The first time: right-click AutoApply in Applications > Open > Open.
   (This test build isn't notarized by Apple yet, so a normal double-click is blocked once.)
   If macOS still refuses: System Settings > Privacy & Security > "Open Anyway".
3. Follow the setup. The System check installs what's missing with one click each:
   - Claude Code, logged in with your own Claude account (the agent uses it to think)
   - uv (installs Python for the agent automatically)
   - Node.js (for unusual application sites)
   - Google Chrome
   Then "Install agent" sets up the background agent (first time: a few minutes).

Needs macOS 26 or later on an Apple Silicon Mac.
Everything stays on your Mac; only job descriptions, form questions and your profile
text are sent to Claude to write answers.
TXT
OUT="$APP_DIR/build/AutoApply-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "AutoApply $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
echo "Built $OUT"
