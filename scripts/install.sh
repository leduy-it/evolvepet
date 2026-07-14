#!/usr/bin/env bash
# One command to get evolvepet running: build the app from source, install it to
# /Applications, and launch it. On first launch the app copies in its bundled
# evolving pets and auto-connects tracking for Claude Code / Codex — nothing else
# to configure.
#
#   ./scripts/install.sh                                   # from a clone
#   curl -fsSL https://raw.githubusercontent.com/leduy-it/evolvepet/main/scripts/install.sh | bash
#
# Building from source needs the Swift toolchain (Xcode or the Command Line
# Tools). If you don't have it, download the prebuilt, notarized .dmg from the
# Releases page instead — that needs no toolchain.
set -euo pipefail

REPO_URL="https://github.com/leduy-it/evolvepet"
APP_NAME="AgentPet.app"
DEST="/Applications/$APP_NAME"

info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Toolchain gate. The universal build needs `swift` (and SwiftPM fetching
#    Sparkle over the network). Fail loudly here rather than mid-build.
command -v swift >/dev/null 2>&1 || die \
"the Swift toolchain is required to build from source.
  Install it with:  xcode-select --install
  Or download the prebuilt, notarized .dmg from $REPO_URL/releases"

# 2. Find the source. Run from inside a clone → use it; piped via curl → clone.
if SELF="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)" \
   && [ -f "$SELF/Package.swift" ]; then
  SRC="$SELF"
else
  command -v git >/dev/null 2>&1 || die "git is required to fetch the source."
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT          # don't leave a full checkout behind
  SRC="$TMP/evolvepet"
  info "Cloning $REPO_URL ..."
  git clone --depth 1 "$REPO_URL" "$SRC"
fi

# 3. Build the .app (universal arm64+x86_64, ad-hoc signed). No Xcode project.
info "Building $APP_NAME — the first build takes a few minutes ..."
bash "$SRC/scripts/build-app.sh" release
BUILT="$SRC/build/$APP_NAME"
[ -d "$BUILT" ] || die "build did not produce $BUILT"

# 4. Install into /Applications, replacing any previous copy.
info "Installing to $DEST ..."
# Guard the destructive step: DEST must be the exact app path, never collapse to
# a bare directory even if a future refactor blanks APP_NAME.
[ -n "$APP_NAME" ] && [ "$DEST" = "/Applications/$APP_NAME" ] || die "unsafe install path: '$DEST'"
if [ -e "$DEST" ]; then
  osascript -e 'quit app "AgentPet"' >/dev/null 2>&1 || true  # release a busy bundle
  rm -rf "$DEST"
fi
cp -R "$BUILT" "$DEST"

# 5. Launch. A locally-built app has no com.apple.quarantine xattr, so Gatekeeper
#    does not prompt. First run installs the bundled evolving pets and connects
#    tracking for the agents you have.
info "Launching ..."
open "$DEST"

cat <<'DONE'

  ✓ evolvepet is running in your menu bar.
    • Its evolving pet is set up and levels up as you code.
    • Tracking auto-connects for Claude Code and Codex (change it in Settings).
DONE
