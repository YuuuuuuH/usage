#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/Codex Token Atlas.app"
CONTENTS_DIR="$APP_DIR/Contents"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-token-atlas-build.XXXXXX")"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

command -v xcrun >/dev/null
command -v codesign >/dev/null

/usr/bin/python3 -m py_compile "$ROOT_DIR/src/codex_token_heatmap.py"
/usr/bin/python3 "$ROOT_DIR/src/codex_token_heatmap.py" --self-test

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"

xcrun swiftc \
  -O \
  -parse-as-library \
  -target arm64-apple-macos12.0 \
  -framework AppKit \
  -framework WebKit \
  "$ROOT_DIR/macos/CodexTokenAtlasApp.swift" \
  -o "$TEMP_DIR/CodexTokenAtlas-arm64"

xcrun swiftc \
  -O \
  -parse-as-library \
  -target x86_64-apple-macos12.0 \
  -framework AppKit \
  -framework WebKit \
  "$ROOT_DIR/macos/CodexTokenAtlasApp.swift" \
  -o "$TEMP_DIR/CodexTokenAtlas-x86_64"

xcrun lipo \
  -create \
  "$TEMP_DIR/CodexTokenAtlas-arm64" \
  "$TEMP_DIR/CodexTokenAtlas-x86_64" \
  -output "$CONTENTS_DIR/MacOS/CodexTokenAtlas"

install -m 0644 "$ROOT_DIR/macos/Info.plist" "$CONTENTS_DIR/Info.plist"
install -m 0644 "$ROOT_DIR/assets/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
install -m 0644 "$ROOT_DIR/src/codex_token_heatmap.py" "$CONTENTS_DIR/Resources/codex_token_heatmap.py"

codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "Built: $APP_DIR"
