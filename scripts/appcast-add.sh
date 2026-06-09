#!/usr/bin/env bash
#
# Append a new <item> entry to appcast.xml for a release artifact.
#
# Called from the GitHub Actions release workflow once notarization
# completes. Signs the release ZIP with the maintainer's Sparkle
# EdDSA private key, computes the file length, and emits a Sparkle-
# compatible appcast item that points at the GitHub release download.
#
# Usage:
#   scripts/appcast-add.sh \
#     --zip imsg-relay-arm64.zip \
#     --version 0.1.0 \
#     --build 42 \
#     --download-url https://github.com/ranaroussi/imsg-relay/releases/download/v0.1.0/imsg-relay-arm64.zip \
#     --min-system 13.0 \
#     --notes-url https://github.com/ranaroussi/imsg-relay/releases/tag/v0.1.0
#
# Reads the EdDSA private key from $SPARKLE_ED_PRIVATE_KEY (env), or
# from --private-key <path> if you'd rather pass a file.
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APPCAST="$PROJECT_DIR/appcast.xml"

zip_path=""
version=""
build_number=""
download_url=""
min_system="13.0"
notes_url=""
private_key_path=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --zip)            zip_path="$2";          shift 2 ;;
        --version)        version="$2";           shift 2 ;;
        --build)          build_number="$2";      shift 2 ;;
        --download-url)   download_url="$2";      shift 2 ;;
        --min-system)     min_system="$2";        shift 2 ;;
        --notes-url)      notes_url="$2";         shift 2 ;;
        --private-key)    private_key_path="$2";  shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

for need in zip_path version build_number download_url; do
    if [ -z "${!need}" ]; then
        echo "missing --${need//_/-}" >&2
        exit 1
    fi
done

if [ ! -f "$zip_path" ]; then
    echo "zip not found: $zip_path" >&2
    exit 1
fi

if [ -z "$private_key_path" ] && [ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    echo "either --private-key <path> or env SPARKLE_ED_PRIVATE_KEY is required" >&2
    exit 1
fi

# Locate Sparkle's sign_update binary. Sparkle is distributed through
# SwiftPM as a binary .xcframework artifact, with the maintainer
# helpers under .build/artifacts/sparkle/Sparkle/bin/. The bundle /
# framework paths are legacy fallbacks in case Sparkle ever ships in
# the older `Sparkle_Sparkle.bundle` shape again.
SIGN_UPDATE=""
for candidate in \
    "$PROJECT_DIR/src/.build/artifacts/sparkle/Sparkle/bin/sign_update" \
    "$PROJECT_DIR/src/.build/checkouts/Sparkle/bin/sign_update" \
    "$PROJECT_DIR/src/.build/release/Sparkle_Sparkle.bundle/Contents/Resources/sign_update" \
    "$PROJECT_DIR/src/.build/debug/Sparkle_Sparkle.bundle/Contents/Resources/sign_update" \
    "$PROJECT_DIR/src/.build/release/Sparkle.framework/Versions/B/Resources/sign_update" \
    "$PROJECT_DIR/src/.build/debug/Sparkle.framework/Versions/B/Resources/sign_update"
do
    if [ -x "$candidate" ]; then
        SIGN_UPDATE="$candidate"
        break
    fi
done

if [ -z "$SIGN_UPDATE" ]; then
    echo "couldn't find Sparkle's sign_update binary — run 'cd src && swift build -c release' first" >&2
    echo "expected: src/.build/artifacts/sparkle/Sparkle/bin/sign_update" >&2
    exit 1
fi

if [ -n "$private_key_path" ]; then
    key_arg=(-f "$private_key_path")
else
    # Pipe the env-var key through a temp file because sign_update only
    # accepts the key via -f, not stdin / a flag.
    tmp_key="$(mktemp)"
    trap 'rm -f "$tmp_key"' EXIT
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$tmp_key"
    chmod 600 "$tmp_key"
    key_arg=(-f "$tmp_key")
fi

ed_signature="$("$SIGN_UPDATE" "${key_arg[@]}" "$zip_path")"
# sign_update outputs lines like 'sparkle:edSignature="...." length="...."',
# so the result is ready to paste into the enclosure tag almost verbatim.

# Use Python to compute the file length and to do the appcast XML edit
# (sed/awk gets too brittle once the XML grows past a few entries).
python3 - "$APPCAST" "$version" "$build_number" "$download_url" "$min_system" "$notes_url" "$zip_path" "$ed_signature" <<'PY'
import os, sys, datetime, xml.etree.ElementTree as ET

appcast_path, version, build_number, download_url, min_system, notes_url, zip_path, ed_signature = sys.argv[1:]
file_length = os.path.getsize(zip_path)
pub_date = datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S %z')

# `ed_signature` from sign_update looks like:
#   sparkle:edSignature="abc==" length="12345"
# We already have the length from os.path.getsize, but sign_update's
# value is what Sparkle verifies against — so take it as the source of
# truth for both.
attrs = {}
for part in ed_signature.split():
    if '=' not in part:
        continue
    key, _, val = part.partition('=')
    attrs[key.strip()] = val.strip().strip('"')

ed_sig = attrs.get('sparkle:edSignature', '')
length = attrs.get('length', str(file_length))

# Register namespace so xml.etree emits sparkle:* tags correctly.
SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE_NS)

tree = ET.parse(appcast_path)
root = tree.getroot()
channel = root.find('channel')
if channel is None:
    raise SystemExit("appcast.xml is malformed: <channel> missing")

# Build the new item.
item = ET.Element('item')
ET.SubElement(item, 'title').text = f'Version {version}'
ET.SubElement(item, 'pubDate').text = pub_date
if notes_url:
    link_el = ET.SubElement(item, 'link')
    link_el.text = notes_url
    notes_el = ET.SubElement(item, f'{{{SPARKLE_NS}}}releaseNotesLink')
    notes_el.text = notes_url
ET.SubElement(item, f'{{{SPARKLE_NS}}}version').text = build_number
ET.SubElement(item, f'{{{SPARKLE_NS}}}shortVersionString').text = version
ET.SubElement(item, f'{{{SPARKLE_NS}}}minimumSystemVersion').text = min_system

enclosure = ET.SubElement(item, 'enclosure')
enclosure.set('url', download_url)
enclosure.set('length', length)
enclosure.set('type', 'application/octet-stream')
if ed_sig:
    enclosure.set(f'{{{SPARKLE_NS}}}edSignature', ed_sig)

# Drop any pre-existing item for the same version (idempotent re-runs).
for existing in list(channel.findall('item')):
    short = existing.find(f'{{{SPARKLE_NS}}}shortVersionString')
    if short is not None and short.text == version:
        channel.remove(existing)

# Insert as the first item so newest is on top.
first_item_idx = None
for i, child in enumerate(list(channel)):
    if child.tag == 'item':
        first_item_idx = i
        break
if first_item_idx is None:
    channel.append(item)
else:
    channel.insert(first_item_idx, item)

ET.indent(tree, space='    ')
tree.write(appcast_path, encoding='utf-8', xml_declaration=True)
print(f"✓ appended {version} (build {build_number}) to {appcast_path}", file=sys.stderr)
PY

echo "appcast.xml updated for v$version"
