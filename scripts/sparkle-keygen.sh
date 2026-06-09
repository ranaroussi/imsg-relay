#!/usr/bin/env bash
#
# One-time Sparkle ED25519 keypair generation.
#
# Run locally as a project maintainer the first time you set up release
# automation. The keypair authenticates auto-update artifacts: Sparkle on
# the user's Mac verifies every downloaded build against the embedded
# `SUPublicEDKey` before installing it. If the private key leaks, anyone
# can publish updates that look legit to existing installs.
#
# Outputs:
#
#   build/sparkle-keys/ed_public_key   — paste into GitHub repo secret SPARKLE_ED_PUBLIC_KEY,
#                                        and into a build-time secret of the same name
#                                        so create-app-bundle.sh can inject it into Info.plist.
#   build/sparkle-keys/ed_private_key  — paste into GitHub repo secret SPARKLE_ED_PRIVATE_KEY.
#                                        DO NOT commit, share, or back up to a public store.
#
# The output directory is in .gitignore. Delete it once you've moved the
# keys into GitHub secrets (or your password manager).
#
# Re-running this script overwrites whatever was there. Don't — losing the
# private key means every previously-shipped install has to be reinstalled
# manually before they can auto-update again.
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$PROJECT_DIR/build/sparkle-keys"

if [ -f "$OUT_DIR/ed_private_key" ]; then
    echo "✗ $OUT_DIR/ed_private_key already exists." >&2
    echo "  Refusing to overwrite — see comments at the top of this script for why." >&2
    echo "  If you really want a fresh keypair, delete the file first." >&2
    exit 1
fi

# Sparkle is distributed through SwiftPM as a binary .xcframework
# artifact. The maintainer helper binaries (generate_keys + sign_update)
# ship in a sibling `bin/` directory under `.build/artifacts/sparkle/`.
#
# The .bundle / .framework fallbacks below are legacy paths kept for
# safety if Sparkle's distribution shape ever changes back — they're
# also the layout sparkle-project.org's old docs reference.
GENERATE_KEYS=""
for candidate in \
    "$PROJECT_DIR/src/.build/artifacts/sparkle/Sparkle/bin/generate_keys" \
    "$PROJECT_DIR/src/.build/checkouts/Sparkle/bin/generate_keys" \
    "$PROJECT_DIR/src/.build/release/Sparkle_Sparkle.bundle/Contents/Resources/generate_keys" \
    "$PROJECT_DIR/src/.build/debug/Sparkle_Sparkle.bundle/Contents/Resources/generate_keys" \
    "$PROJECT_DIR/src/.build/release/Sparkle.framework/Versions/B/Resources/generate_keys" \
    "$PROJECT_DIR/src/.build/debug/Sparkle.framework/Versions/B/Resources/generate_keys"
do
    if [ -x "$candidate" ]; then
        GENERATE_KEYS="$candidate"
        break
    fi
done

if [ -z "$GENERATE_KEYS" ]; then
    echo "✗ Couldn't find Sparkle's generate_keys." >&2
    echo "  Run 'cd src && swift build -c release' first to materialize Sparkle's binary artifact." >&2
    echo "  Expected location: src/.build/artifacts/sparkle/Sparkle/bin/generate_keys" >&2
    exit 1
fi
echo "→ Using generate_keys at: ${GENERATE_KEYS#$PROJECT_DIR/}"

mkdir -p "$OUT_DIR"

# Account name used when storing the private key in the Keychain. Keying
# under a project-specific account keeps this keypair from colliding
# with any other Sparkle-using projects on the same Mac.
ACCOUNT="imsg-relay"

# Sparkle's generate_keys CLI shape:
#   (no flags)            generate (or look up existing) keypair, store
#                         private in Keychain, print public-key info to stdout
#   -p                    print existing Keychain public key only
#   -x <file>             EXPORT Keychain private key to file
#   -f <file>             IMPORT a private key file INTO Keychain
#                         (NOT "write generated key to file" — easy
#                         misread; this is the opposite direction)
#
# So the maintainer flow is two calls:
#   1. plain `generate_keys` — creates the keypair in Keychain, prints public
#   2. `generate_keys -x <file>` — exports private from Keychain to file
#
# macOS will pop a Keychain access dialog on step 1 the first time.
# Click "Always Allow" so step 2 doesn't prompt again.

echo "→ Generating Sparkle ED25519 keypair under Keychain account '$ACCOUNT'…"
echo "  (macOS will prompt you to allow Keychain access — click 'Always Allow')"

set +e
public_output="$("$GENERATE_KEYS" --account "$ACCOUNT" 2>&1)"
gen_status=$?
set -e

if [ $gen_status -ne 0 ]; then
    echo "✗ generate_keys failed:" >&2
    echo "$public_output" >&2
    exit 1
fi

# generate_keys prints something like:
#     <key>SUPublicEDKey</key>
#     <string>BASE64_PUBLIC_KEY_HERE</string>
# along with a bunch of explanatory text. Extract the base64 line that
# looks like a real public key (ed25519 public keys are 32 raw bytes →
# 44 chars of base64, including the trailing `=`).
public_key="$(printf '%s\n' "$public_output" | grep -oE '[A-Za-z0-9+/]{42,}=*' | head -n1)"

if [ -z "$public_key" ]; then
    echo "✗ Couldn't extract public key from generate_keys output." >&2
    echo "  Raw output follows for debugging:" >&2
    printf '%s\n' "$public_output" >&2
    exit 1
fi

printf '%s\n' "$public_key" > "$OUT_DIR/ed_public_key"

echo "→ Exporting private key from Keychain to file…"
"$GENERATE_KEYS" --account "$ACCOUNT" -x "$OUT_DIR/ed_private_key" >/dev/null

chmod 600 "$OUT_DIR/ed_private_key"
chmod 644 "$OUT_DIR/ed_public_key"

echo
echo "✓ Generated:"
echo "    $OUT_DIR/ed_public_key   ($(wc -c < "$OUT_DIR/ed_public_key" | tr -d ' ') bytes)"
echo "    $OUT_DIR/ed_private_key  ($(wc -c < "$OUT_DIR/ed_private_key" | tr -d ' ') bytes)"
echo
echo "Next steps:"
echo "  1. Add GitHub repo secret SPARKLE_ED_PUBLIC_KEY  ← contents of ed_public_key"
echo "  2. Add GitHub repo secret SPARKLE_ED_PRIVATE_KEY ← contents of ed_private_key"
echo "  3. ALSO paste the public key into src/Info.plist as the value of"
echo "     <key>SUPublicEDKey</key>, and commit (so dev builds can verify"
echo "     updates locally too)."
echo "  4. Back up ed_private_key in a password manager."
echo "  5. Delete $OUT_DIR once both keys are stored safely (Keychain still"
echo "     has a copy under the '$ACCOUNT' account — keep that as a local backup)."
echo
echo "Public key (copy this into Info.plist and the SPARKLE_ED_PUBLIC_KEY secret):"
echo
cat "$OUT_DIR/ed_public_key"
echo
