#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/Token Atlas.app"
CONTENTS_DIR="$APP_DIR/Contents"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-token-atlas-build.XXXXXX")"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

command -v xcrun >/dev/null
command -v codesign >/dev/null

/usr/bin/python3 -m py_compile "$ROOT_DIR/src/token_atlas.py" "$ROOT_DIR/scripts/claude_quota_bridge.py" "$ROOT_DIR/scripts/antigravity_quota.py"
/usr/bin/python3 "$ROOT_DIR/src/token_atlas.py" --self-test
/usr/bin/python3 -m unittest discover -s "$ROOT_DIR/tests" -p 'test_*.py'

xcrun swiftc \
  -O \
  -parse-as-library \
  "$ROOT_DIR/macos/LiveTokenMonitor.swift" \
  "$ROOT_DIR/tests/LiveTokenMonitorTests.swift" \
  -o "$TEMP_DIR/LiveTokenMonitorTests"
"$TEMP_DIR/LiveTokenMonitorTests"

xcrun swiftc -O -parse-as-library \
  "$ROOT_DIR/macos/AtlasTheme.swift" \
  "$ROOT_DIR/tests/AtlasThemeTests.swift" \
  -o "$TEMP_DIR/AtlasThemeTests"
"$TEMP_DIR/AtlasThemeTests"

xcrun swiftc -O -parse-as-library \
  "$ROOT_DIR/macos/AtlasHoverTooltip.swift" \
  "$ROOT_DIR/tests/AtlasHoverTooltipTests.swift" \
  -o "$TEMP_DIR/AtlasHoverTooltipTests"
"$TEMP_DIR/AtlasHoverTooltipTests"

xcrun swiftc -O -parse-as-library \
  "$ROOT_DIR/macos/AtlasReportSnapshot.swift" \
  "$ROOT_DIR/tests/AtlasReportSnapshotTests.swift" \
  -o "$TEMP_DIR/AtlasReportSnapshotTests"
"$TEMP_DIR/AtlasReportSnapshotTests"

xcrun swiftc -O -parse-as-library \
  "$ROOT_DIR/macos/UsageQuota.swift" \
  "$ROOT_DIR/tests/UsageQuotaTests.swift" \
  -o "$TEMP_DIR/UsageQuotaTests"
"$TEMP_DIR/UsageQuotaTests"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"

xcrun swiftc \
  -O \
  -parse-as-library \
  -target arm64-apple-macos12.0 \
  -framework AppKit \
  -framework SwiftUI \
  "$ROOT_DIR/macos/AtlasTheme.swift" \
  "$ROOT_DIR/macos/LiveTokenMonitor.swift" \
  "$ROOT_DIR/macos/AtlasHoverTooltip.swift" \
  "$ROOT_DIR/macos/AtlasReportSnapshot.swift" \
  "$ROOT_DIR/macos/UsageQuota.swift" \
  "$ROOT_DIR/macos/QuotaPopover.swift" \
  "$ROOT_DIR/macos/TokenAtlasApp.swift" \
  -o "$TEMP_DIR/TokenAtlas-arm64"

xcrun swiftc \
  -O \
  -parse-as-library \
  -target x86_64-apple-macos12.0 \
  -framework AppKit \
  -framework SwiftUI \
  "$ROOT_DIR/macos/AtlasTheme.swift" \
  "$ROOT_DIR/macos/LiveTokenMonitor.swift" \
  "$ROOT_DIR/macos/AtlasHoverTooltip.swift" \
  "$ROOT_DIR/macos/AtlasReportSnapshot.swift" \
  "$ROOT_DIR/macos/UsageQuota.swift" \
  "$ROOT_DIR/macos/QuotaPopover.swift" \
  "$ROOT_DIR/macos/TokenAtlasApp.swift" \
  -o "$TEMP_DIR/TokenAtlas-x86_64"

xcrun lipo \
  -create \
  "$TEMP_DIR/TokenAtlas-arm64" \
  "$TEMP_DIR/TokenAtlas-x86_64" \
  -output "$CONTENTS_DIR/MacOS/TokenAtlas"

install -m 0644 "$ROOT_DIR/macos/Info.plist" "$CONTENTS_DIR/Info.plist"
xcrun swift "$ROOT_DIR/scripts/render_icon.swift" "$TEMP_DIR/AppIcon.iconset"
iconutil -c icns "$TEMP_DIR/AppIcon.iconset" -o "$CONTENTS_DIR/Resources/AppIcon.icns"
install -m 0644 "$ROOT_DIR/src/token_atlas.py" "$CONTENTS_DIR/Resources/token_atlas.py"
install -m 0644 "$ROOT_DIR/scripts/claude_quota_bridge.py" "$CONTENTS_DIR/Resources/claude_quota_bridge.py"
install -m 0644 "$ROOT_DIR/scripts/antigravity_quota.py" "$CONTENTS_DIR/Resources/antigravity_quota.py"

codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "Built: $APP_DIR"
