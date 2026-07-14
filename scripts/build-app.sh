#!/usr/bin/env bash
# Assembles AgentPet.app from a release build so it runs as a proper menu bar
# app (bundle id, LSUIElement, working notifications). Ad-hoc signed for local
# testing. Notarization + DMG + Homebrew are issue #13.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/build/AgentPet.app"
CONFIG="${1:-release}"

# A universal binary (Apple Silicon + Intel) needs Xcode's xcbuild, which ships
# only with full Xcode — not the standalone Command Line Tools. When only the CLT
# are present we build natively for this machine's architecture: still a valid,
# runnable app, just with one slice. CI (full Xcode) and the notarized DMG stay
# universal. Detect by probing for xcbuild rather than guessing from the path.
DEVDIR="$(xcode-select -p 2>/dev/null || true)"
if [ -n "$DEVDIR" ] && [ -x "$DEVDIR/../SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild" ]; then
    ARCHS=(--arch arm64 --arch x86_64)
    echo "Building ($CONFIG, universal arm64 + x86_64)..."
else
    ARCHS=()
    echo "Building ($CONFIG, native $(uname -m) — full Xcode not found, universal skipped)..."
fi

# ${ARCHS[@]+…} keeps this safe on macOS's stock bash 3.2 under `set -u` when the
# array is empty (a bare "${ARCHS[@]}" would fault as an unbound variable there).
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"}
BINDIR="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

echo "Assembling $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINDIR/agentpet" "$APP/Contents/MacOS/agentpet"
cp "$ROOT/scripts/AppInfo.plist" "$APP/Contents/Info.plist"
# Sparkle compares the appcast's sparkle:version against the installed
# CFBundleVersion, and the appcast publishes the marketing version. Force
# CFBundleVersion == CFBundleShortVersionString so they can never drift (which
# would make Sparkle offer the same update forever).
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $SHORT_VERSION" "$APP/Contents/Info.plist"
[ -f "$ROOT/scripts/AppIcon.icns" ] && cp "$ROOT/scripts/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Localizations (en/vi/zh-Hans). Copied into the .app so Bundle.main picks the
# user's system language automatically for SwiftUI Text + NSLocalizedString.
if [ -d "$ROOT/Localizations" ]; then
    for lproj in "$ROOT/Localizations"/*.lproj; do
        [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
    done
fi

# The agentpet target now ships a resource (the donate QR), so SwiftPM emits
# AgentPet_agentpet.bundle. Copy it so Bundle.module resolves inside the .app.
if [ -d "$BINDIR/AgentPet_agentpet.bundle" ]; then
    cp -R "$BINDIR/AgentPet_agentpet.bundle" "$APP/Contents/Resources/"
fi

# Bundle Sparkle.framework (auto-update). SwiftPM links it via @rpath but does
# not place it inside a hand-assembled .app, so we copy it into Frameworks and
# point the binary's rpath there. ditto preserves the framework symlinks.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BINDIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/agentpet" 2>/dev/null || true

# Ad-hoc sign for local testing (release.sh re-signs with a Developer ID).
# Sign the framework first (inside-out) so the outer app signature is valid.
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework" || true
codesign --force --sign - "$APP" || echo "warning: codesign failed (continuing unsigned)"

echo "Done: $APP"
echo "Run with: open \"$APP\"   (or: \"$APP/Contents/MacOS/agentpet\")"
