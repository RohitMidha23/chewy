#!/usr/bin/env bash
#
# build-app.sh — assemble a self-contained, ad-hoc-signed Chewy.app
# menu-bar application from the SwiftPM build products.
#
# Output:
#   dist/Chewy.app   — the installable app bundle
#   dist/Chewy.zip   — a zip of the app for distribution
#
set -euo pipefail

# --- locate the repo root so the script works from any CWD -------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="Chewy"
DISPLAY_NAME="Chewy"
BUNDLE_ID="io.github.rohitmidha23.chewy"
SHORT_VERSION="0.1.0"
BUNDLE_VERSION="1"

DIST_DIR="$REPO_ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
RELEASE_DIR="$REPO_ROOT/.build/release"
RESOURCE_BUNDLE="Chewy_ChewyApp.bundle"

echo "==> Building $DISPLAY_NAME (release)…"
swift build -c release

# --- sanity: the executable must exist ---------------------------------------
if [[ ! -f "$RELEASE_DIR/$APP_NAME" ]]; then
  echo "error: expected executable not found at $RELEASE_DIR/$APP_NAME" >&2
  exit 1
fi

# --- clean + assemble the bundle skeleton ------------------------------------
echo "==> Assembling bundle at $APP_DIR"
rm -rf "$DIST_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

# 1) main executable
cp "$RELEASE_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

# 2) SwiftPM resource bundle (the logos, so Bundle.module works inside the app)
if [[ -d "$RELEASE_DIR/$RESOURCE_BUNDLE" ]]; then
  cp -R "$RELEASE_DIR/$RESOURCE_BUNDLE" "$RES_DIR/$RESOURCE_BUNDLE"
  echo "    + copied $RESOURCE_BUNDLE"
else
  echo "warning: $RESOURCE_BUNDLE not found in $RELEASE_DIR — logos may not load" >&2
fi

# 3) optional app icon: Tools/appicon.png -> AppIcon.icns (skip gracefully)
ICON_PLIST_ENTRY=""
APPICON_SRC="$REPO_ROOT/Tools/appicon.png"
if [[ -f "$APPICON_SRC" ]]; then
  echo "==> Generating AppIcon.icns from Tools/appicon.png"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 64 128 256 512; do
    sips -z "$size" "$size"     "$APPICON_SRC" --out "$ICONSET/icon_${size}x${size}.png"     >/dev/null 2>&1 || true
    dbl=$((size * 2))
    sips -z "$dbl" "$dbl"       "$APPICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png"  >/dev/null 2>&1 || true
  done
  if iconutil -c icns "$ICONSET" -o "$RES_DIR/AppIcon.icns" 2>/dev/null; then
    ICON_PLIST_ENTRY="    <key>CFBundleIconFile</key>
    <string>AppIcon</string>"
    echo "    + AppIcon.icns generated"
  else
    echo "    ! iconutil failed; continuing without an app icon"
  fi
else
  echo "==> No Tools/appicon.png; skipping app icon (this is fine)"
fi

# 5) Info.plist
echo "==> Writing Info.plist"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUNDLE_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
$ICON_PLIST_ENTRY
</dict>
</plist>
PLIST

# --- codesign ----------------------------------------------------------------
# Ad-hoc signing only — no Apple Developer account or certificate required.
# macOS will treat each rebuild as a new app, so the Keychain may re-prompt for
# access after a rebuild; click "Always Allow" when it does.
echo "==> Ad-hoc codesigning"
codesign --force --deep --sign - "$APP_DIR"
codesign -dv "$APP_DIR" 2>&1 | sed 's/^/    /'

# --- zip ---------------------------------------------------------------------
echo "==> Zipping"
( cd "$DIST_DIR" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$APP_NAME.zip" )

# --- done --------------------------------------------------------------------
echo ""
echo "SUCCESS — $DISPLAY_NAME built."
echo "  App : $APP_DIR"
echo "  Zip : $DIST_DIR/$APP_NAME.zip"
echo ""
echo "Install: drag dist/$APP_NAME.app to /Applications, then right-click -> Open the first time."
