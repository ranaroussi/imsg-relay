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

log "Resolving and patching Swift dependencies"
(cd "$SRC_DIR" && swift package resolve)
IMSG_DEPENDENCY_PATCH="$SRC_DIR/.build/checkouts/imsg/scripts/patch-deps.sh"
[ -f "$IMSG_DEPENDENCY_PATCH" ] || die "IMsgCore dependency patch missing: $IMSG_DEPENDENCY_PATCH"
(cd "$SRC_DIR" && bash ".build/checkouts/imsg/scripts/patch-deps.sh")

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

# Package resources belong under Contents/Resources in a signed macOS app.
# IMsgCore's dependency patch makes PhoneNumberKit search this standard path
# in release builds instead of falling through to SwiftPM's CLI-only path.
for bundle in "$BUILD_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done

RELAY_RESOURCE_BUNDLE="$APP_DIR/Contents/Resources/${EXECUTABLE_NAME}_${EXECUTABLE_NAME}.bundle"
[ -d "$RELAY_RESOURCE_BUNDLE" ] || die "SwiftPM resource bundle missing: $RELAY_RESOURCE_BUNDLE"
PHONE_NUMBER_RESOURCE_BUNDLE="$APP_DIR/Contents/Resources/PhoneNumberKit_PhoneNumberKit.bundle"
[ -d "$PHONE_NUMBER_RESOURCE_BUNDLE" ] || die "PhoneNumberKit resource bundle missing: $PHONE_NUMBER_RESOURCE_BUNDLE"

# Every release up to 0.1.3 launched fine on the build machine and died
# instantly everywhere else. SwiftPM's generated `Bundle.module` accessor
# probes `<app>.app/ImsgRelay_ImsgRelay.bundle` — a path this bundler never
# writes — then falls back to an absolute path inside the build machine's
# checkout, and calls `fatalError` when neither resolves. Because the icon
# loader ran before anything drew UI and LSUIElement suppresses the crash
# dialog, the app just silently failed to open. Guard the invariant instead
# of the symptom: our code must resolve resources through `Bundle.main`.
log "Verifying bundle is self-contained"

RELAY_MODULE_USES="$(grep -rn 'Bundle\.module' "$SRC_DIR/Sources" --include='*.swift' \
    | sed 's/^[^:]*:[0-9]*://' \
    | sed 's/^[[:space:]]*//' \
    | grep -v '^//' || true)"
if [ -n "$RELAY_MODULE_USES" ]; then
    die "Bundle.module used in Sources — reintroduces the silent launch crash, use Bundle.main: $RELAY_MODULE_USES"
fi

# Linking that accessor is what bakes our own bundle name into the binary, so
# its absence is the post-build proof the app no longer depends on a path we
# do not ship.
if strings "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME" \
    | grep -q "${EXECUTABLE_NAME}_${EXECUTABLE_NAME}.bundle"; then
    die "Binary references ${EXECUTABLE_NAME}_${EXECUTABLE_NAME}.bundle — the Bundle.module accessor was linked in"
fi

# The exact file menuBarImage() now loads through Bundle.main.
MENU_BAR_ICON="$APP_DIR/Contents/Resources/MenuBarIcon@2x.png"
[ -f "$MENU_BAR_ICON" ] || die "Menu bar icon missing: $MENU_BAR_ICON"

# Dependencies keep their own generated accessors. PhoneNumberKit's patched
# resolver checks Bundle.main.resourceURL first, so its dev path survives only
# as an unreachable fallback — reported rather than fatal, so a genuinely
# reachable one cannot hide in the noise.
EMBEDDED_DEV_PATHS="$(strings "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME" \
    | grep -o "/Users/[^\"' ]*\.bundle" | sort -u || true)"
if [ -n "$EMBEDDED_DEV_PATHS" ]; then
    warn "Dependency fallback paths embedded (unreachable in a packaged app):"
    printf '%s\n' "$EMBEDDED_DEV_PATHS" | sed 's/^/      /'
fi
ok "Self-contained: no build-machine paths reachable, menu bar icon present"

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

# Inject Sparkle EdDSA public key when provided by CI. Local dev builds
# inherit whatever's already in Info.plist (typically empty during
# bring-up; once you've run scripts/sparkle-keygen.sh and pasted the
# pub key into Info.plist it'll be set there too). Sparkle aborts if
# the key isn't a valid base64 string, so an empty value here means
# "skip the updater" — AppDelegate handles that gracefully.
if [ -n "${SPARKLE_ED_PUBLIC_KEY:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey ${SPARKLE_ED_PUBLIC_KEY}" "$APP_DIR/Contents/Info.plist" \
        || /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${SPARKLE_ED_PUBLIC_KEY}" "$APP_DIR/Contents/Info.plist"
    ok "Embedded Sparkle SUPublicEDKey"
fi

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
