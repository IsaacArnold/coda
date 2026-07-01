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

# App assets live FLAT under Contents/Resources so the bundle code-signs cleanly.
# A SwiftPM resource bundle (Coda_Coda.bundle) is a directory with a `.bundle`
# extension and no Info.plist, which `codesign` rejects ("bundle format
# unrecognized") — that blocks Developer-ID signing and notarization. Worse, its
# generated accessor falls back to an absolute *build-machine* path, so the old
# layout crashed on launch on any other Mac. Instead we copy the bundle's
# *contents* (its Resources/ and Themes/ subdirs) into Contents/Resources, where
# `Bundle.main` resolves them — see Sources/Coda/ResourceBundle.swift.
#
# SwiftTerm_SwiftTerm.bundle (Metal shaders) is intentionally NOT shipped: Coda
# uses the AppKit renderer and never takes SwiftTerm's Metal path, so SwiftTerm
# never loads it. (If a future change opts into SwiftTerm's Metal renderer, that
# bundle must be shipped where SwiftTerm's own Bundle.module accessor finds it.)
CODA_BUNDLE="$BIN_DIR/Coda_Coda.bundle"
[[ -d "$CODA_BUNDLE" ]] || { echo "ERROR: $CODA_BUNDLE not found"; exit 1; }
cp -R "$CODA_BUNDLE/." "$APP/Contents/Resources/"

# App icon for Finder/Dock (CFBundleIconFile).
cp "$REPO_ROOT/Sources/Coda/Resources/Coda.icns" "$APP/Contents/Resources/$APP_NAME.icns"

# Make the bundle user-writable so the recipient's `xattr -dr com.apple.quarantine`
# unblock step (unsigned path only) can remove the attribute.
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

# --- sign ------------------------------------------------------------------
# Two modes:
#   • Local (default): keep the ad-hoc signature `swift build` already applied to
#     the Mach-O (all Apple Silicon needs to execute; `cp` preserves it). Now that
#     assets are flat in Contents/Resources we CAN seal the whole bundle, so we do
#     an ad-hoc bundle seal too — it costs nothing and keeps the dev/release paths
#     identical. Gatekeeper still blocks recipients once (see README-INSTALL).
#   • Release: set DEVELOPER_ID_APP to your
#       "Developer ID Application: Your Name (TEAMID)"
#     identity to seal with the Hardened Runtime, which notarization requires.
#     No --entitlements are passed because Coda needs none: it is NOT sandboxed,
#     and spawning child processes (/bin/zsh, git, /usr/bin/open) is allowed by
#     default under the Hardened Runtime. With assets flat in Contents/Resources
#     there are no nested bundles, so one seal (no --deep) covers everything.
WILL_NOTARIZE=0
if [[ -n "${DEVELOPER_ID_APP:-}" ]]; then
  echo "==> Signing with Developer ID + Hardened Runtime"
  echo "    identity: $DEVELOPER_ID_APP"
  SIGN_ARGS=(--force --options runtime --timestamp --sign "$DEVELOPER_ID_APP")
  [[ -n "${ENTITLEMENTS:-}" ]] && SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
  codesign "${SIGN_ARGS[@]}" "$APP"
  echo "==> Verifying signature"
  codesign --verify --strict --verbose=2 "$APP"
  if [[ -n "${NOTARY_PROFILE:-}" ]] \
     || { [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; }; then
    WILL_NOTARIZE=1
  else
    echo "    NOTE: signed but no notary credentials set — skipping notarization."
    echo "          Recipients stay blocked by Gatekeeper until this is notarized."
    echo "          Set NOTARY_PROFILE (from: xcrun notarytool store-credentials), or"
    echo "          NOTARY_APPLE_ID + NOTARY_TEAM_ID + NOTARY_PASSWORD (app-specific pw)."
  fi
else
  echo "==> Ad-hoc signature only (set DEVELOPER_ID_APP to sign + notarize)"
  codesign --force --sign - "$APP"
  codesign --verify --strict "$APP" \
    && echo "    bundle is ad-hoc sealed (ok to run on Apple Silicon)" \
    || echo "    WARNING: ad-hoc seal failed — the app may not launch"
fi

# --- install instructions (shipped inside the dmg) -------------------------
if [[ "$WILL_NOTARIZE" == "1" ]]; then
cat > "$DIST/README-INSTALL.txt" <<TXT
Installing Coda
===============

1. Drag Coda.app into the Applications folder (shortcut provided).
2. Double-click to open. That's it — Coda is signed and notarized by Apple,
   so Gatekeeper opens it with no warning, on any Mac.
TXT
else
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
fi

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

# --- notarize + staple -----------------------------------------------------
# Upload to Apple's notary service (automated malware scan; not App Review),
# then staple the ticket onto the dmg so Gatekeeper verifies it offline.
if [[ "$WILL_NOTARIZE" == "1" ]]; then
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
  else
    NOTARY_AUTH=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
  fi
  echo "==> Submitting to Apple notary service (can take a few minutes)"
  # --timeout bounds the whole submit+wait so a stalled upload/connection can't
  # hang indefinitely (notarytool has no default timeout). Normal runs finish in
  # well under this; on timeout the non-zero exit trips `set -e` and we abort
  # before publishing. Re-running is safe — a hung submit never registers.
  xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait --timeout 30m
  echo "==> Stapling the notarization ticket"
  xcrun stapler staple "$DMG"
  # The dmg is the distributed artifact; also staple the loose .app (best effort:
  # its code hash was notarized as part of the dmg, so this normally succeeds).
  xcrun stapler staple "$APP" \
    || echo "    (loose .app not stapled — the dmg is stapled, which is what ships)"
  # Assess the .app, not the .dmg: a dmg is notarized + stapled but never
  # code-signed, so `spctl` on the dmg reports "no usable signature" — a false
  # alarm. The .app is what Gatekeeper actually evaluates once Homebrew (or a
  # manual drag) copies it to /Applications; it should read "Notarized Developer ID".
  echo "==> Gatekeeper check (assessing the .app)"
  spctl -a -vv "$APP" || true
fi

echo ""
echo "Done."
echo "  App: $APP"
echo "  DMG: $DMG"
[[ "$WILL_NOTARIZE" == "1" ]] && echo "  Signed + notarized — opens with no Gatekeeper warning."
