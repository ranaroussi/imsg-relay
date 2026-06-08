#!/usr/bin/env bash
#
# Build the imsg-relay .app bundle from the SwiftPM release binary.
# Designed to run identically on a developer Mac (ad-hoc signature)
# and in CI with Developer ID credentials.
#
set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { printf "${BLUE}==>${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}✓${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}!${NC} %s\n" "$*"; }
die()  { printf "${RED}✗${NC} %s\n" "$*" >&2; exit 1; }

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$PROJECT_DIR/src"
APP_NAME="iMessage Relay"
EXECUTABLE_NAME="ImsgRelay"
BUNDLE_ID="com.imsg-relay.app"
APP_DIR="$PROJECT_DIR/$APP_NAME.app"

TARGET_ARCH="${TARGET_ARCH:-$(uname -m)}"
# Normalize uname -m output (arm64 / x86_64) into SwiftPM arch flags.
case "$TARGET_ARCH" in
    arm64|aarch64) SWIFT_ARCH="arm64"; CLOUDFLARED_ARCH="darwin-arm64" ;;
    x86_64|amd64)  SWIFT_ARCH="x86_64"; CLOUDFLARED_ARCH="darwin-amd64" ;;
    *) die "Unsupported architecture: $TARGET_ARCH" ;;
esac

BUILD_DIR="$SRC_DIR/.build/release"

log "Building Swift executable (release, $SWIFT_ARCH)"
(cd "$SRC_DIR" && swift build -c release --arch "$SWIFT_ARCH")
[ -f "$BUILD_DIR/$EXECUTABLE_NAME" ] || die "Build output missing: $BUILD_DIR/$EXECUTABLE_NAME"
ok "Built $BUILD_DIR/$EXECUTABLE_NAME"

log "Creating .app skeleton"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

cp "$BUILD_DIR/$EXECUTABLE_NAME" "$APP_DIR/Contents/MacOS/"
chmod +x "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
install_name_tool -add_rpath "@loader_path/../Frameworks" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME" 2>/dev/null || true

log "Copying bundled resources"
if [ -d "$SRC_DIR/Sources/Resources" ]; then
    for item in "$SRC_DIR/Sources/Resources/"*; do
        [ -e "$item" ] || continue
        name="$(basename "$item")"
        case "$name" in
            *.swift|README.md) continue ;;
        esac
        cp -R "$item" "$APP_DIR/Contents/Resources/"
    done
fi

# Some IMsgCore/SwiftPM resource layouts produce an ImsgRelay_ImsgRelay.bundle
# under .build/release. Copy it alongside the binary so resource lookups work.
for bundle in "$BUILD_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done

log "Bundling cloudflared ($CLOUDFLARED_ARCH)"
CFD_OUT="$APP_DIR/Contents/Resources/cloudflared"
if [ -f "$SRC_DIR/Sources/Resources/cloudflared" ]; then
    cp "$SRC_DIR/Sources/Resources/cloudflared" "$CFD_OUT"
elif command -v cloudflared >/dev/null 2>&1; then
    warn "Using system cloudflared from PATH for dev bundle"
    cp "$(command -v cloudflared)" "$CFD_OUT"
else
    warn "No cloudflared found locally; downloading latest release"
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${CLOUDFLARED_ARCH}" \
        -o "$CFD_OUT" || die "Failed to download cloudflared"
fi
chmod +x "$CFD_OUT"
ok "cloudflared bundled: $(ls -lh "$CFD_OUT" | awk '{print $5}')"

log "Bundling Sparkle.framework"
SPARKLE_FRAMEWORK="$BUILD_DIR/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    cp -R "$SPARKLE_FRAMEWORK" "$APP_DIR/Contents/Frameworks/"
    ok "Sparkle.framework bundled"
else
    warn "Sparkle.framework not found at $SPARKLE_FRAMEWORK (auto-updates disabled)"
fi

log "Installing Info.plist"
cp "$SRC_DIR/Info.plist" "$APP_DIR/Contents/"

VERSION="${APP_VERSION:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null || echo 0.1.0)"
    VERSION="${VERSION#v}"
fi
BUILD_NUMBER="$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_DIR/Contents/Info.plist"
ok "Version $VERSION (build $BUILD_NUMBER)"

echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

log "Code signing"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$CODESIGN_IDENTITY" ]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)"
fi

xattr -cr "$APP_DIR" 2>/dev/null || true

if [ -n "$CODESIGN_IDENTITY" ]; then
    log "Signing with Developer ID: $CODESIGN_IDENTITY"

    if [ -f "$APP_DIR/Contents/Resources/cloudflared" ]; then
        codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
            "$APP_DIR/Contents/Resources/cloudflared"
        ok "cloudflared signed"
    fi

    if [ -d "$APP_DIR/Contents/Frameworks/Sparkle.framework" ]; then
        SPARKLE_FW="$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B"
        SPARKLE_ENT="$PROJECT_DIR/sparkle-entitlements.plist"
        for xpc in "$SPARKLE_FW/XPCServices"/*.xpc; do
            [ -d "$xpc" ] || continue
            codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
                --entitlements "$SPARKLE_ENT" "$xpc"
        done
        codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
            --entitlements "$SPARKLE_ENT" "$SPARKLE_FW/Autoupdate" 2>/dev/null || true
        codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
            --entitlements "$SPARKLE_ENT" "$SPARKLE_FW/Updater.app" 2>/dev/null || true
        codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
            "$APP_DIR/Contents/Frameworks/Sparkle.framework"
        ok "Sparkle.framework signed"
    fi

    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
        --entitlements "$PROJECT_DIR/entitlements.plist" \
        "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
    codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
        --entitlements "$PROJECT_DIR/entitlements.plist" \
        "$APP_DIR"
    codesign --verify --deep --strict --verbose=2 "$APP_DIR"
    ok "Signed and verified"
else
    warn "No Developer ID found — using ad-hoc signature (dev builds only)"
    codesign --force --deep --sign - "$APP_DIR"
fi

ok "App bundle ready: $APP_DIR"
