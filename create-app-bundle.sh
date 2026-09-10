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

# Shipped builds are universal, so one download runs everywhere.
#
# This is not just a convenience: Sparkle's appcast carries one <enclosure>
# per channel and has no notion of architecture, so a per-arch release forces
# a choice of which half of the user base gets handed a binary their Mac
# cannot execute. Rosetta doesn't save it either — it translates x86_64 on
# Apple Silicon, never arm64 on Intel. Releases 0.1.0 through 0.1.4 published
# an arm64-only enclosure for exactly that reason.
#
# Set TARGET_ARCH=arm64 (or x86_64) for a faster single-arch dev build.
TARGET_ARCH="${TARGET_ARCH:-universal}"
case "$TARGET_ARCH" in
    universal)     SWIFT_ARCHS=(arm64 x86_64) ;;
    arm64|aarch64) SWIFT_ARCHS=(arm64) ;;
    x86_64|amd64)  SWIFT_ARCHS=(x86_64) ;;
    *) die "Unsupported TARGET_ARCH: $TARGET_ARCH (expected universal, arm64, or x86_64)" ;;
esac

# `swift build --arch X` writes to .build/<arch>-apple-macosx/release, and the
# convenient .build/release symlink points at whichever arch was built *last*
# — silently wrong the moment we build two. Address the per-arch trees.
arch_build_dir() { printf '%s/.build/%s-apple-macosx/release' "$SRC_DIR" "$1"; }
BUILD_DIR="$(arch_build_dir "${SWIFT_ARCHS[0]}")"

# True when $1 is a Mach-O file carrying every arch named in $2..$n.
binary_has_archs() {
    local bin="$1"; shift
    local present want
    present="$(lipo -archs "$bin" 2>/dev/null || true)"
    for want in "$@"; do
        printf '%s\n' $present | grep -qx "$want" || return 1
    done
}

log "Resolving and patching Swift dependencies"
(cd "$SRC_DIR" && swift package resolve)
IMSG_DEPENDENCY_PATCH="$SRC_DIR/.build/checkouts/imsg/scripts/patch-deps.sh"
[ -f "$IMSG_DEPENDENCY_PATCH" ] || die "IMsgCore dependency patch missing: $IMSG_DEPENDENCY_PATCH"
(cd "$SRC_DIR" && bash ".build/checkouts/imsg/scripts/patch-deps.sh")

for arch in "${SWIFT_ARCHS[@]}"; do
    log "Building Swift executable (release, $arch)"
    (cd "$SRC_DIR" && swift build -c release --arch "$arch")
    [ -f "$(arch_build_dir "$arch")/$EXECUTABLE_NAME" ] \
        || die "Build output missing: $(arch_build_dir "$arch")/$EXECUTABLE_NAME"
done
ok "Built: ${SWIFT_ARCHS[*]}"

log "Creating .app skeleton"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

if [ "${#SWIFT_ARCHS[@]}" -gt 1 ]; then
    LIPO_INPUTS=()
    for arch in "${SWIFT_ARCHS[@]}"; do
        LIPO_INPUTS+=("$(arch_build_dir "$arch")/$EXECUTABLE_NAME")
    done
    lipo -create "${LIPO_INPUTS[@]}" -output "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME" \
        || die "lipo failed to merge ${SWIFT_ARCHS[*]}"
    ok "Merged universal executable ($(lipo -archs "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"))"
else
    cp "$BUILD_DIR/$EXECUTABLE_NAME" "$APP_DIR/Contents/MacOS/"
fi
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

log "Bundling cloudflared (${SWIFT_ARCHS[*]})"
CFD_OUT="$APP_DIR/Contents/Resources/cloudflared"

# Cloudflare ships macOS cloudflared as a .tgz containing a single binary.
# The bare-binary assets they used to publish at `cloudflared-darwin-<arch>`
# were withdrawn and now 404, which is why this fetches the archive.
cloudflared_asset_for() {
    case "$1" in
        arm64)  printf 'cloudflared-darwin-arm64.tgz' ;;
        x86_64) printf 'cloudflared-darwin-amd64.tgz' ;;
        *) die "No cloudflared asset known for arch: $1" ;;
    esac
}

fetch_cloudflared_slice() {
    local arch="$1" dest="$2" asset tmp extracted
    asset="$(cloudflared_asset_for "$arch")"
    tmp="$(mktemp -d)"
    curl -fSL --retry 3 --retry-delay 2 \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/$asset" \
        -o "$tmp/cloudflared.tgz" || { rm -rf "$tmp"; die "Failed to download $asset"; }
    tar -xzf "$tmp/cloudflared.tgz" -C "$tmp" || { rm -rf "$tmp"; die "Failed to extract $asset"; }
    # The top-level filename has varied between `cloudflared` and
    # `cloudflared-darwin-<arch>` across releases.
    extracted="$(find "$tmp" -maxdepth 2 -type f -name 'cloudflared*' ! -name '*.tgz' | head -n1)"
    [ -n "$extracted" ] || { rm -rf "$tmp"; die "No cloudflared binary inside $asset"; }
    mv "$extracted" "$dest"
    rm -rf "$tmp"
    chmod +x "$dest"
}

# A local candidate is only usable if it covers every arch we're shipping —
# otherwise the tunnel would be dead on exactly the Macs this universal
# build exists to support, and only at runtime, long after CI went green.
CFD_CANDIDATE=""
if [ -f "$SRC_DIR/Sources/Resources/cloudflared" ]; then
    CFD_CANDIDATE="$SRC_DIR/Sources/Resources/cloudflared"
elif command -v cloudflared >/dev/null 2>&1; then
    CFD_CANDIDATE="$(command -v cloudflared)"
fi

if [ -n "$CFD_CANDIDATE" ] && binary_has_archs "$CFD_CANDIDATE" "${SWIFT_ARCHS[@]}"; then
    cp "$CFD_CANDIDATE" "$CFD_OUT"
    ok "Reused cloudflared from ${CFD_CANDIDATE#$PROJECT_DIR/}"
else
    if [ -n "$CFD_CANDIDATE" ]; then
        warn "Local cloudflared covers only [$(lipo -archs "$CFD_CANDIDATE" 2>/dev/null || echo unknown)] — fetching instead"
    fi
    CFD_TMP="$(mktemp -d)"
    fetch_cloudflared_slice "${SWIFT_ARCHS[0]}" "$CFD_TMP/${SWIFT_ARCHS[0]}"
    if binary_has_archs "$CFD_TMP/${SWIFT_ARCHS[0]}" "${SWIFT_ARCHS[@]}"; then
        # Cloudflare started shipping a fat binary; nothing to merge.
        mv "$CFD_TMP/${SWIFT_ARCHS[0]}" "$CFD_OUT"
    else
        # Avoid array slicing (${a[@]:1}) — it trips `set -u` under the
        # bash 3.2 that ships with macOS when the tail is empty.
        CFD_SLICES=()
        for arch in "${SWIFT_ARCHS[@]}"; do
            [ -f "$CFD_TMP/$arch" ] || fetch_cloudflared_slice "$arch" "$CFD_TMP/$arch"
            CFD_SLICES+=("$CFD_TMP/$arch")
        done
        if [ "${#CFD_SLICES[@]}" -gt 1 ]; then
            lipo -create "${CFD_SLICES[@]}" -output "$CFD_OUT" \
                || { rm -rf "$CFD_TMP"; die "lipo failed to merge cloudflared slices"; }
        else
            mv "${CFD_SLICES[0]}" "$CFD_OUT"
        fi
    fi
    rm -rf "$CFD_TMP"
fi
chmod +x "$CFD_OUT"
ok "cloudflared bundled: $(ls -lh "$CFD_OUT" | awk '{print $5}') ($(lipo -archs "$CFD_OUT"))"

log "Bundling Sparkle.framework"
SPARKLE_FRAMEWORK="$BUILD_DIR/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    cp -R "$SPARKLE_FRAMEWORK" "$APP_DIR/Contents/Frameworks/"
    ok "Sparkle.framework bundled"
else
    warn "Sparkle.framework not found at $SPARKLE_FRAMEWORK (auto-updates disabled)"
fi

log "Verifying architectures (${SWIFT_ARCHS[*]})"
# A thin slice that slips through here doesn't fail in CI — it fails as a
# dyld crash on a user's Mac, on the machines this build exists to serve.
# Sparkle counts as much as our own executable: a missing slice in a linked
# framework takes the whole app down at launch, not just the updater.
# Sparkle is addressed through its version symlink, not the current letter
# ("B"): a hardcoded letter that stops matching makes the check below skip
# the framework entirely and pass, which is the one outcome a verification
# gate must never do.
SPARKLE_BIN="Contents/Frameworks/Sparkle.framework/Versions/Current/Sparkle"
if [ -d "$APP_DIR/Contents/Frameworks/Sparkle.framework" ] && [ ! -f "$APP_DIR/$SPARKLE_BIN" ]; then
    die "Sparkle.framework is bundled but $SPARKLE_BIN does not resolve — cannot verify its slices"
fi

for rel in \
    "Contents/MacOS/$EXECUTABLE_NAME" \
    "Contents/Resources/cloudflared" \
    "$SPARKLE_BIN"
do
    bin="$APP_DIR/$rel"
    [ -f "$bin" ] || continue
    if binary_has_archs "$bin" "${SWIFT_ARCHS[@]}"; then
        ok "$(basename "$bin"): $(lipo -archs "$bin")"
    else
        die "$rel covers only [$(lipo -archs "$bin" 2>/dev/null || echo unknown)] — need ${SWIFT_ARCHS[*]}"
    fi
done

log "Installing Info.plist"
cp "$SRC_DIR/Info.plist" "$APP_DIR/Contents/"

# Releases pass APP_VERSION from the tag. Everything else is a development
# build and takes the baseline declared in src/Info.plist.
#
# Deliberately *not* falling back to `git describe --tags`: that makes a local
# build claim to be the latest release, so the updater sees nothing newer and a
# dev build can never test the update path. The hardcoded `0.1.0` that used to
# sit behind it was worse still — it went stale the moment 0.1.1 shipped, and
# outranked the plist it was meant to mirror.
VERSION="${APP_VERSION:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC_DIR/Info.plist" 2>/dev/null || echo '')"
fi
VERSION="${VERSION#v}"
[ -n "$VERSION" ] || die "no version: pass APP_VERSION, or set CFBundleShortVersionString in src/Info.plist"

# CFBundleVersion is the number Sparkle actually compares. It counts commits
# rather than mirroring $VERSION because the installed base is already on that
# scale — 0.1.4 shipped as build 44 — and Sparkle's comparator reads "44" as
# newer than "0.2.0" (44 > 0 on the first component), so switching to mirroring
# would tell every existing user they were already current.
#
# Two things can silently produce a *lower* number than the installed app has,
# which is the same bug wearing a different hat, so both are fatal:
#   - a shallow clone (CI without fetch-depth: 0) counts a handful of commits
#   - no git at all used to fall back to `1`
# The floor is src/Info.plist's CFBundleVersion, which exists for no other
# reason than to record the highest build number published so far.
git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 \
    || die "CFBundleVersion is derived from the commit count and this is not a git checkout"
if [ "$(git -C "$PROJECT_DIR" rev-parse --is-shallow-repository)" = "true" ]; then
    die "shallow clone: the commit count would understate CFBundleVersion and Sparkle would read the release as a downgrade (use fetch-depth: 0)"
fi
BUILD_NUMBER="$(git -C "$PROJECT_DIR" rev-list --count HEAD)"
BUILD_FLOOR="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SRC_DIR/Info.plist" 2>/dev/null || echo 0)"
if [ "$BUILD_NUMBER" -lt "$BUILD_FLOOR" ]; then
    die "build number $BUILD_NUMBER is below the last published $BUILD_FLOOR — Sparkle would treat this release as a downgrade"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_DIR/Contents/Info.plist"
ok "Version $VERSION (build $BUILD_NUMBER, floor $BUILD_FLOOR)"

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
