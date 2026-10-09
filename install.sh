#!/bin/bash
# DeskTime.app install / update karta hai.
#  - Sirf dashboard (UI) badla ho to app dobara build nahi hoti — bas naya UI copy hota hai,
#    isliye macOS permission dobara nahi maangta.
#  - app/DeskTime.swift badla ho tabhi app build hoti hai (tab Accessibility permission ek baar dobara deni padti hai).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/DeskTime.app"
DATA="$HOME/Library/Application Support/DeskTimeTracker"
STAMP="$DATA/.build-stamp"

mkdir -p "$DATA/web"
chmod 700 "$DATA"

# 1) Dashboard files (UI) — app inhe yahin se padhti hai
cp "$DIR/dashboard_template.html" "$DIR/app/vendor/echarts.min.js" "$DATA/web/"
[ -f "$DATA/categories.json" ] || cp "$DIR/categories.json" "$DATA/categories.json"
chmod 700 "$DATA/web"
chmod 600 "$DATA/categories.json" "$DATA/web/"*
echo "✅ Dashboard updated."

# 2) App sirf tab build karo jab uska code badla ho
HASH="$(cat "$DIR/app/DeskTime.swift" "$DIR/app/Info.plist" "$DIR/app/make_icon.swift" | shasum -a 256 | cut -d' ' -f1)"
if [ -d "$APP" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$HASH" ]; then
  echo "   App code unchanged — no rebuild needed."
  pgrep -x DeskTime >/dev/null || open "$APP"
  exit 0
fi

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
B="$BUILD/DeskTime.app/Contents"
mkdir -p "$B/MacOS" "$B/Resources"
echo "🔨 Building the app..."
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" "$DIR/app/DeskTime.swift" -o "$B/MacOS/DeskTime"
swift "$DIR/app/make_icon.swift" "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$B/Resources/AppIcon.icns"
cp "$DIR/app/Info.plist" "$B/Info.plist"
cp "$DIR/dashboard_template.html" "$DIR/app/vendor/echarts.min.js" "$DIR/categories.json" "$B/Resources/"
# Signature: agar aapne "DeskTime Local Signing" certificate trust kiya hai to usse sign karo —
# tab rebuild ke baad bhi Accessibility permission bani rehti hai. Warna ad-hoc (har rebuild pe permission dobara).
# Trust karne ke liye (password maangega, aapki marzi):
#   security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db \
#     ~/Library/Application\ Support/DeskTimeTracker/signing/cert.pem
KC="$DATA/signing/desktime.keychain-db"
SIGN="-"
if [ -f "$KC" ] && [ -f "$DATA/signing/.pw" ]; then
  security unlock-keychain -p "$(cat "$DATA/signing/.pw")" "$KC" 2>/dev/null || true
  if security find-identity -v -p codesigning "$KC" 2>/dev/null | grep -q "DeskTime Local Signing"; then SIGN="DeskTime Local Signing"; fi
fi
if [ "$SIGN" = "-" ]; then
  codesign --force --sign - "$BUILD/DeskTime.app"
else
  codesign --force --keychain "$KC" --sign "$SIGN" "$BUILD/DeskTime.app"
  echo "   Signed with DeskTime Local Signing (permissions survive rebuilds)."
fi

# Chalti app ko aaram se band karo (force-kill nahi)
if pgrep -x DeskTime >/dev/null; then
  osascript -e 'tell application "DeskTime" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do pgrep -x DeskTime >/dev/null || break; sleep 1; done
fi
mkdir -p "$HOME/Applications"
[ -d "$APP" ] && rm -rf "$HOME/Applications/DeskTime.app"
mv "$BUILD/DeskTime.app" "$APP"
echo "$HASH" > "$STAMP"
open "$APP"
echo "✅ DeskTime.app is running — look for the DeskTime icon in the menu bar."
echo "   For window titles: System Settings → Privacy & Security → Accessibility → turn DeskTime on"
