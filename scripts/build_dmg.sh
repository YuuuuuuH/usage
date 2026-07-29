#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/Codex Token Atlas.app"
DMG_PATH="$DIST_DIR/Codex Token Atlas.dmg"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-token-atlas-dmg.XXXXXX")"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

"$ROOT_DIR/scripts/build_app.sh"

ditto "$APP_DIR" "$STAGING_DIR/Codex Token Atlas.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -ov \
  -volname "Codex Token Atlas" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_PATH"

hdiutil verify "$DMG_PATH"
echo "Built: $DMG_PATH"
