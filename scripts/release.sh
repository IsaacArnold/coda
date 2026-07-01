#!/usr/bin/env bash
#
# release.sh — cut a public Coda release in one command.
#
# Pipeline:
#   1. build + sign + notarize + staple the dmg   (delegates to make-app.sh)
#   2. verify the dmg is actually stapled          (refuse to ship otherwise)
#   3. compute its sha256
#   4. rewrite version + sha256 in the canonical cask (packaging/homebrew/coda.rb)
#   5. publish the dmg as a GitHub Release on the PUBLIC tap repo
#   6. copy the cask into the tap repo and push it
#
# After this runs, colleagues (incl. on locked-down Macs) get the new version via:
#   brew upgrade --cask coda
#
# Prerequisites (one-time):
#   • An Apple Developer ID cert + notary credentials. Set, every release:
#       export DEVELOPER_ID_APP="Developer ID Application: NAME (TEAMID)"
#       export NOTARY_PROFILE=coda-notary     # from: xcrun notarytool store-credentials
#   • The PUBLIC tap repo exists: https://github.com/IsaacArnold/homebrew-coda
#   • `gh` CLI installed and authenticated (gh auth status).
#
# Usage:
#   VERSION=0.1.0 scripts/release.sh        # explicit version (recommended)
#   scripts/release.sh                      # version from latest git tag
#   DRY_RUN=1 VERSION=0.1.0 scripts/release.sh   # build + render cask, publish nothing
#
set -euo pipefail

APP_NAME="Coda"
TAP_REPO="${TAP_REPO:-IsaacArnold/homebrew-coda}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TAP_DIR="${TAP_DIR:-$REPO_ROOT/../homebrew-coda}"
CASK="$REPO_ROOT/packaging/homebrew/coda.rb"

die() { echo "ERROR: $*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------
command -v gh >/dev/null   || die "gh CLI not found (brew install gh, then gh auth login)."
command -v shasum >/dev/null || die "shasum not found."
[[ -f "$CASK" ]] || die "canonical cask missing: $CASK"
[[ -n "${DEVELOPER_ID_APP:-}" ]] \
  || die "DEVELOPER_ID_APP not set — refusing to publish an un-notarized build to a public tap."
[[ -n "${NOTARY_PROFILE:-}" ]] \
  || [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]] \
  || die "No notary credentials — set NOTARY_PROFILE (or NOTARY_APPLE_ID/TEAM_ID/PASSWORD)."

# --- version (mirror make-app.sh) ------------------------------------------
if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
  VERSION="${VERSION:-}"
  [[ -n "$VERSION" ]] || die "No VERSION given and no git tag found. Pass VERSION=x.y.z."
fi
TAG="v$VERSION"
echo "==> Releasing $APP_NAME $VERSION (tag $TAG) to $TAP_REPO"

# --- 0. test gate ----------------------------------------------------------
# Never publish a release that fails its own suite. `swift test` needs XCTest,
# which ships only with a full Xcode, not the CommandLineTools. On this machine
# the CommandLineTools toolchain that builds the release has no XCTest, and the
# installed Xcode can be a different Swift version — so when we fall back to Xcode
# for tests we hand it a SEPARATE scratch dir (.build-test) so its build products
# never collide with the CommandLineTools release build in .build/.
# SKIP_TESTS=1 bypasses the gate (not recommended for a real release).
if [[ -n "${SKIP_TESTS:-}" ]]; then
  echo "==> SKIP_TESTS set — skipping the test gate (not recommended)"
elif xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
  echo "==> Running test suite (swift test)"
  swift test || die "tests failed — aborting release."
elif [[ -d /Applications/Xcode.app ]]; then
  echo "==> Running test suite via /Applications/Xcode.app (CommandLineTools has no XCTest)"
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --scratch-path "$REPO_ROOT/.build-test" \
    || die "tests failed — aborting release."
else
  die "no XCTest-capable toolchain found — install full Xcode, or set SKIP_TESTS=1 to bypass."
fi

# --- 1. build + notarize ---------------------------------------------------
VERSION="$VERSION" "$REPO_ROOT/scripts/make-app.sh"
DMG="$REPO_ROOT/dist/$APP_NAME-$VERSION.dmg"
[[ -f "$DMG" ]] || die "expected dmg not found: $DMG"

# --- 2. verify it is actually stapled --------------------------------------
echo "==> Validating notarization staple"
xcrun stapler validate "$DMG" \
  || die "dmg is not stapled/notarized — aborting before publish. Check make-app.sh notary output."

# --- 3. checksum -----------------------------------------------------------
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "==> sha256: $SHA"

# --- 4. rewrite the canonical cask -----------------------------------------
# Update only the version/sha256 string literals; leave the rest untouched.
/usr/bin/sed -i '' -E \
  -e "s/^([[:space:]]*version )\"[^\"]*\"/\1\"$VERSION\"/" \
  -e "s/^([[:space:]]*sha256 )\"[^\"]*\"/\1\"$SHA\"/" \
  "$CASK"
echo "==> Updated $CASK -> version $VERSION, sha256 $SHA"

if [[ -n "${DRY_RUN:-}" ]]; then
  echo ""
  echo "DRY_RUN set — built + stapled the dmg and rewrote the cask, but published nothing."
  echo "  dmg:  $DMG"
  echo "  cask: $CASK"
  exit 0
fi

# --- 5. push the cask into the tap repo ------------------------------------
# This MUST come before creating the release: a brand-new tap repo has no
# commits, so it has no default branch for `gh release create` to tag against
# ("Repository is empty"). Pushing the cask establishes that branch.
if [[ ! -d "$TAP_DIR/.git" ]]; then
  echo "==> Cloning $TAP_REPO into $TAP_DIR"
  gh repo clone "$TAP_REPO" "$TAP_DIR"
fi
# Give the public tap a landing README the first time someone lands on it.
if [[ ! -f "$TAP_DIR/README.md" ]]; then
  cat > "$TAP_DIR/README.md" <<'MD'
# homebrew-coda

Homebrew tap for [Coda](https://github.com/IsaacArnold/coda).

```sh
brew tap isaacarnold/coda
brew install --cask coda
```

Update later with `brew upgrade --cask coda`.
MD
fi
mkdir -p "$TAP_DIR/Casks"
cp "$CASK" "$TAP_DIR/Casks/coda.rb"
git -C "$TAP_DIR" add README.md Casks/coda.rb
if git -C "$TAP_DIR" diff --cached --quiet; then
  echo "==> Tap already up to date — nothing to push"
else
  git -C "$TAP_DIR" commit -m "coda $VERSION"
  # `push -u origin HEAD` creates the default branch on a first-ever (empty) push.
  git -C "$TAP_DIR" push -u origin HEAD
  echo "==> Pushed cask $VERSION to $TAP_REPO"
fi

# --- 6. publish the dmg as a GitHub Release on the tap repo -----------------
if gh release view "$TAG" --repo "$TAP_REPO" >/dev/null 2>&1; then
  echo "==> Release $TAG already exists on $TAP_REPO — uploading dmg (clobber)"
  gh release upload "$TAG" "$DMG" --repo "$TAP_REPO" --clobber
else
  echo "==> Creating release $TAG on $TAP_REPO"
  gh release create "$TAG" "$DMG" \
    --repo "$TAP_REPO" \
    --title "$APP_NAME $VERSION" \
    --notes "Coda $VERSION. Install: \`brew tap isaacarnold/coda && brew install --cask coda\`"
fi

echo ""
echo "Done. Colleagues update with:  brew upgrade --cask coda"
echo "Remember to commit the bumped cask here too:  git add $CASK"
