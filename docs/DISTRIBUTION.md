# Distribution Guide

How to ship iMessage Relay to real users — code-signed, notarized, auto-updating.

This is a one-time setup guide. After you've finished section 1, every subsequent release is just `git tag v0.x.y && git push --tags` and CI does the rest.

---

## 1. One-time maintainer setup

### 1.1 Apple Developer ID (for code signing + notarization)

You need a paid Apple Developer Program membership ($99/yr). Once enrolled:

1. **Developer ID Application certificate.**
   - Sign in to [developer.apple.com](https://developer.apple.com/account/resources/certificates/list).
   - Create a new certificate of type **Developer ID Application**.
   - Download the `.cer`, double-click to import into Keychain Access.
   - Export it from Keychain (Login → My Certificates → right-click → Export) as a `.p12`. Pick a password you'll paste into a secret in a minute.
   - Base64-encode the file:
     ```bash
     base64 -i Certificates.p12 | pbcopy
     ```
2. **App-specific password.**
   - At [appleid.apple.com](https://appleid.apple.com) → Sign-in & Security → App-Specific Passwords → Generate. Label it `imsg-relay-notarytool`.
3. **Team ID.**
   - Visible at the top-right of [developer.apple.com/account](https://developer.apple.com/account) once signed in.

Add these as repository secrets in **GitHub → Settings → Secrets and variables → Actions**:

| Secret name | Value |
|---|---|
| `APPLE_DEVELOPER_CERTIFICATE_P12_BASE64` | The base64 blob from step 1 |
| `APPLE_DEVELOPER_CERTIFICATE_PASSWORD`   | Password used when exporting the `.p12` |
| `APPLE_DEVELOPER_ID_APPLICATION`         | The full identity string, e.g. `Developer ID Application: Your Name (TEAMID123)` |
| `APPLE_ID`                               | Your Apple ID email |
| `APPLE_TEAM_ID`                          | 10-character team ID from step 3 |
| `APPLE_APP_SPECIFIC_PASSWORD`            | App-specific password from step 2 |

If you skip these the workflow falls back to ad-hoc signing — fine for `act` runs, useless for shipping to actual users (Gatekeeper will refuse).

### 1.2 Sparkle EdDSA keypair (for auto-updates)

Sparkle uses an ED25519 keypair to authenticate update bundles. The private key signs releases; the public key is embedded in every installed copy of the app and verifies downloads before installing them. **If the private key leaks, you have to re-key the app (which means every existing install has to re-install manually).**

Generate it once:

```bash
cd src && swift build -c release    # need this so Sparkle's `generate_keys` binary exists
cd ..
./scripts/sparkle-keygen.sh
```

The script writes `build/sparkle-keys/ed_public_key` and `build/sparkle-keys/ed_private_key`. Add two more repo secrets:

| Secret name | Value |
|---|---|
| `SPARKLE_ED_PUBLIC_KEY`  | Contents of `ed_public_key` (single base64 line) |
| `SPARKLE_ED_PRIVATE_KEY` | Contents of `ed_private_key` (single base64 line) |

Also paste the public key into `src/Info.plist` as the value of `<key>SUPublicEDKey</key>`, and commit. This bakes the verifier into local dev builds too so a buggy debug-build update path doesn't accidentally install unsigned artifacts.

Once both keys are stored in GitHub secrets (and the public key is in `Info.plist`), **delete `build/sparkle-keys/`** — `.gitignore` already excludes it, but better to not have the private key sitting on disk.

### 1.3 Branding metadata

Decide on:

- `SUFeedURL` in `Info.plist` — points at the raw URL of `appcast.xml` on the default branch. Default already set to `https://raw.githubusercontent.com/ranaroussi/imsg-relay/main/appcast.xml`; change to your fork if you're publishing your own.
- `CFBundleIdentifier` — currently `com.imsg-relay.app`. If you fork, change this so your auto-updates don't collide with the upstream.

---

## 2. Every release

```bash
# 1. Tag your commit with a SemVer version.
git tag v0.2.0
git push origin v0.2.0
```

That's it. The workflow at `.github/workflows/release.yml` then:

1. Builds the arm64 + x86_64 `.app` bundles (matrix job).
2. Imports the Developer ID cert.
3. Injects `SPARKLE_ED_PUBLIC_KEY` into `Info.plist` and `CFBundleShortVersionString` from the tag.
4. Code-signs the bundle (Sparkle XPC services, cloudflared, the main binary, the outer `.app`).
5. Notarizes via `xcrun notarytool submit --wait`, then `xcrun stapler staple`.
6. Packages `.zip` and `.dmg`, generates `.sha256` checksums.
7. Uploads everything as a GitHub release attached to the tag.
8. (`appcast` job) Signs the release ZIP with the EdDSA private key via Sparkle's `sign_update`, prepends a fresh `<item>` block to `appcast.xml`, commits and pushes to `main`.

Existing installs poll `appcast.xml` once a day (see `SUScheduledCheckInterval`) and on the next poll see the new version, prompt the user, download, verify the EdDSA signature, and install.

### Cutting a pre-release

Same flow, but use a SemVer suffix:

```bash
git tag v0.2.0-rc1
git push origin v0.2.0-rc1
```

The release is published with `prerelease: false` regardless — if you want it marked as pre-release in GitHub, edit `.github/workflows/release.yml` and add a step that flips that based on tag pattern. (Sparkle has separate handling for `sparkle:channel` filtering if you want a beta lane.)

---

## 3. Manually verifying a release

After publishing, before you tell anyone, smoke-test the released artifact yourself:

```bash
# Pull the artifact from the release page
ARCH=arm64       # or x86_64
ZIP_URL="https://github.com/ranaroussi/imsg-relay/releases/download/v0.2.0/imsg-relay-${ARCH}.zip"
curl -fL "$ZIP_URL" -o /tmp/imsg-relay.zip
curl -fL "$ZIP_URL.sha256" -o /tmp/imsg-relay.zip.sha256

# Verify checksum
cd /tmp && shasum -a 256 -c imsg-relay.zip.sha256

# Unzip and inspect signature + notarization
unzip -q imsg-relay.zip
codesign --verify --deep --strict --verbose=2 "iMessage Relay.app"
spctl -a -vvv -t install "iMessage Relay.app"
# Expected: accepted, source=Notarized Developer ID
```

If Gatekeeper says `rejected`, the notarization step probably timed out — check the workflow run logs and re-run that job.

To verify the appcast itself:

```bash
curl -fL https://raw.githubusercontent.com/ranaroussi/imsg-relay/main/appcast.xml | xmllint --format -
# The first <item> should have your new version's edSignature + enclosure URL.
```

---

## 4. Rotating the Sparkle key

If you suspect the private key has leaked:

1. Generate a fresh keypair with `./scripts/sparkle-keygen.sh` (delete the old `build/sparkle-keys/` first).
2. Replace `SPARKLE_ED_PUBLIC_KEY` and `SPARKLE_ED_PRIVATE_KEY` in GitHub secrets.
3. Update `SUPublicEDKey` in `Info.plist` and commit.
4. Publish a new release as normal.

**Everyone with an existing install will be stranded** — their copy still trusts the old public key, so the auto-update to the new build (signed by the new key) will fail verification. They have to manually re-download from the GitHub release page.

There's no clean migration path for this; it's a one-shot. Keep the private key behind GitHub's secret store and don't paste it into chats / paste-bins / repos.
