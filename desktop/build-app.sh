#!/bin/bash
# Build / refresh Janitor.app (double-click desktop button)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${1:-$ROOT/desktop/Janitor.app}"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
ICON_SRC="$ROOT/desktop/icon/AppIcon.icns"

mkdir -p "$MACOS_DIR" "$RES_DIR"

if [[ ! -f "$ICON_SRC" ]]; then
  echo "Missing $ICON_SRC — run desktop/icon/build-icns.sh first" >&2
  exit 1
fi
cp "$ICON_SRC" "$RES_DIR/AppIcon.icns"

cat >"$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Janitor</string>
  <key>CFBundleDisplayName</key>
  <string>Janitor</string>
  <key>CFBundleIdentifier</key>
  <string>com.susssus.janitor.desktop</string>
  <key>CFBundleVersion</key>
  <string>1.1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.1</string>
  <key>CFBundleExecutable</key>
  <string>Janitor</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleSignature</key>
  <string>????</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>LSUIElement</key>
  <false/>
</dict>
</plist>
EOF

cat >"$MACOS_DIR/Janitor" <<EOF
#!/bin/bash
# Launcher — two-phase Janitor (assess → confirm → clean)
exec "$ROOT/bin/janitor-desktop"
EOF
chmod +x "$MACOS_DIR/Janitor" "$ROOT/bin/janitor-desktop"

# Bump mtime so Finder/Dock refresh the icon
touch "$APP_DIR"

echo "Built: $APP_DIR"
