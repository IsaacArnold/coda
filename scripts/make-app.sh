#!/usr/bin/env bash
#
# make-app.sh — build Coda as a distributable, UNSIGNED macOS .app + .dmg.
#
# This produces an app you (and trusting colleagues) can install like a normal
# Mac app. It is ad-hoc signed only — NOT notarized — so on first launch macOS
# Gatekeeper will block it. See dist/README-INSTALL.txt (generated below) for
# how recipients get past that one-time prompt.
#
# Usage:
#   scripts/make-app.sh                 # version from git tag, else 0.0.0-dev
#   VERSION=1.2.0 scripts/make-app.sh   # explicit marketing version
#
# Output:
#   dist/Coda.app          — the application bundle
#   dist/Coda-<ver>.dmg    — the disk image to hand out
#
set -euo pipefail

APP_NAME="Coda"
BUNDLE_ID="net.branchoutonline.coda"
MIN_MACOS="13.0"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --- version ---------------------------------------------------------------
if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
  VERSION="${VERSION:-0.0.0-dev}"
fi
# CFBundleVersion must be a monotonic integer-ish string; use commit count.
BUILD_NUM="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "==> Building $APP_NAME $VERSION (build $BUILD_NUM)"

# --- compile ---------------------------------------------------------------
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
[[ -x "$BIN_DIR/$APP_NAME" ]] || { echo "ERROR: $BIN_DIR/$APP_NAME not found"; exit 1; }

# --- assemble bundle -------------------------------------------------------
DIST="$REPO_ROOT/dist"
APP="$DIST/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Executable
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# Resource bundles must sit next to the executable (binary uses @loader_path).
# Copy every SwiftPM resource bundle the build produced.
for b in "$BIN_DIR"/*.bundle; do
  [[ -e "$b" ]] && cp -R "$b" "$APP/Contents/MacOS/"
done

# App icon for Finder/Dock.
cp "$REPO_ROOT/Sources/Coda/Resources/Coda.icns" "$APP/Contents/Resources/$APP_NAME.icns"

# SwiftPM ships some resources read-only (e.g. Shaders.metal). That breaks the
# `xattr -dr com.apple.quarantine` un-blocking step recipients run, since
# removing an xattr needs write permission. Make the whole bundle user-writable.
chmod -R u+w "$APP"

# --- Info.plist ------------------------------------------------------------
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>        <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$BUILD_NUM</string>
    <key>LSMinimumSystemVersion</key>  <string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST

# --- ad-hoc sign -----------------------------------------------------------
# Required for the arm64 binary to run at all; also quiets some Gatekeeper
# checks. Not a Developer ID signature — recipients still bypass Gatekeeper once.
# Signature: `swift build` already applies a linker ad-hoc signature to the
# Mach-O, which is all Apple Silicon requires to execute, and `cp` preserves it.
# We intentionally do NOT re-run codesign to seal the whole .app: the SwiftPM
# resource bundles are flat, Info.plist-less data dirs that codesign refuses to
# treat as valid nested bundles, and a full bundle seal buys nothing without a
# Developer ID + notarization. Confirm the executable is signed:
echo "==> Checking ad-hoc signature"
codesign -dv "$APP/Contents/MacOS/$APP_NAME" 2>&1 | grep -q "adhoc" \
  && echo "    executable is ad-hoc signed (ok to run on Apple Silicon)" \
  || echo "    WARNING: executable not signed — it may not launch"

# --- install instructions (shipped inside the dmg) -------------------------
cat > "$DIST/README-INSTALL.txt" <<TXT
Installing Coda
===============

1. Drag Coda.app into the Applications folder (shortcut provided).

2. First launch — macOS will block it because Coda is not notarized by Apple:

   • macOS 14 (Sonoma) or earlier:
       Right-click Coda in Applications -> Open -> click "Open" in the dialog.

   • macOS 15 (Sequoia) or later:
       Double-click it (it gets blocked), then open
       System Settings -> Privacy & Security, scroll down, click
       "Open Anyway", then launch Coda again.

   • Works on every version (Terminal):
       xattr -dr com.apple.quarantine /Applications/Coda.app
       ...then open Coda normally.

   You only do this once per machine (and again after each update).

Tip: if you receive Coda.app via AirDrop or a USB drive instead of a
download, macOS usually won't quarantine it and it just opens.
TXT

# --- dmg -------------------------------------------------------------------
DMG="$DIST/$APP_NAME-$VERSION.dmg"
STAGE="$DIST/.dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp "$DIST/README-INSTALL.txt" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Building dmg"
hdiutil create -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo ""
echo "Done."
echo "  App: $APP"
echo "  DMG: $DMG"
