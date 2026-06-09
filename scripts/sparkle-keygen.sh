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

# Sparkle ships `generate_keys` inside its build artifacts. After a SwiftPM
# build, it lives under .build/<config>/Sparkle_Sparkle.bundle/Contents/Resources/.
GENERATE_KEYS=""
for candidate in \
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
    echo "✗ Couldn't find Sparkle's generate_keys. Run 'swift build' inside src/ first." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

echo "→ Generating Sparkle ED25519 keypair…"
# `generate_keys` prints the new public key to stdout and stores the
# private key in the macOS Keychain by default. We use -f to make it
# write the private key to a file instead so it can be moved into
# GitHub secrets without needing the maintainer's Keychain.
"$GENERATE_KEYS" -f "$OUT_DIR/ed_private_key" > "$OUT_DIR/ed_public_key.tmp"

# Strip surrounding noise; keep only the base64 line.
grep -oE '[A-Za-z0-9+/=]{40,}' "$OUT_DIR/ed_public_key.tmp" | head -n1 > "$OUT_DIR/ed_public_key"
rm "$OUT_DIR/ed_public_key.tmp"

chmod 600 "$OUT_DIR/ed_private_key"
chmod 644 "$OUT_DIR/ed_public_key"

echo
echo "✓ Generated:"
echo "    $OUT_DIR/ed_public_key"
echo "    $OUT_DIR/ed_private_key"
echo
echo "Next steps:"
echo "  1. Copy the public key into the repo's GitHub secret SPARKLE_ED_PUBLIC_KEY."
echo "  2. Copy the private key into the repo's GitHub secret SPARKLE_ED_PRIVATE_KEY."
echo "  3. ALSO paste the public key into src/Info.plist as the value of"
echo "     <key>SUPublicEDKey</key>, and commit (this lets local dev builds"
echo "     verify update bundles too)."
echo "  4. Delete $OUT_DIR once both keys are stored in GitHub secrets."
echo
echo "Public key (copy this into Info.plist and the GitHub secret):"
echo
cat "$OUT_DIR/ed_public_key"
echo
