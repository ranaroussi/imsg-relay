# Changelog

All notable changes to **iMessage Relay** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.1.1] — 2026-06-09

### Changed

- **Settings reorganized into three tabs: Outbound, Inbound, General.**
  Replaces the previous General/Network/Status layout. New mapping:
    - **Outbound** — webhook URL + identifier, stream toggles
      (reactions, backfill), reliability (max retry attempts, moved
      here from Network where it didn't belong).
    - **Inbound** — bearer token (used both as the auth header on
      outbound webhook POSTs AND required on incoming local API /
      MCP calls — one secret, two directions), Cloudflare Tunnel
      config, and a collapsed "Advanced" disclosure for the local
      API + MCP ports that rarely need touching.
    - **General** — Contacts grant/reset, Launch on login, the
      Permissions overview (Full Disk Access + Automation → Messages),
      and About (version, build, bundle ID).

- **Settings window visual polish.** Custom three-tab layout
  replaces the off-the-shelf `Form { Section }` style that no public
  SwiftUI API lets us customize:
    - Section titles are flush-left above each rounded card (no more
      indent baked into the macOS grouped style).
    - Cards are stroke-only (no fill) so they sit cleanly on the
      window's grouped backdrop.
    - Toggles are real macOS-style sliding switches (`.toggleStyle(.switch)`)
      instead of the compact-context checkboxes SwiftUI was picking by
      default.
    - Copyright + GitHub link live in the window footer next to the
      Save button — one persistent footer across all three tabs.
    - Window title trimmed to "iMessage Relay" (was "iMessage Relay
      Settings"). 12px symmetric padding from the window edges.

### Added

- **Launch on login.** New toggle in Settings → General registers
  the app as a macOS login item via `SMAppService.mainApp`. The
  toggle reverts to its actual system state on failure so the UI
  never drifts.

- **MIT LICENSE file** at the repo root. GitHub will now correctly
  detect and surface the license in the repo sidebar.

- **Attachment retrieval docs in README.** New "Fetching the bytes"
  subsection under [Both directions on attachments][attachment-docs]
  with copy-pasteable Node.js + Python examples, an explicit callout
  that the `Bearer ` prefix on `Authorization` is mandatory, and
  guidance on why the response `Content-Type` (transcoded JPEG) may
  differ from `att.mime_type` (original HEIC from chat.db).

[attachment-docs]: README.md#both-directions-on-attachments

### Fixed

- **Contacts permission could not be granted on freshly notarized
  builds.** The Contacts framework requires the
  `com.apple.security.personal-information.addressbook` entitlement
  to be present in the app's code signature. Without it,
  `CNContactStore.requestAccess` returned `.denied` immediately and
  the app never appeared in System Settings → Privacy & Security →
  Contacts. Now embedded in `entitlements.plist` and signed in by
  `create-app-bundle.sh`.

- **TCC service name corrected to legacy `AddressBook`.** The
  Contacts framework's underlying TCC entry is namespaced
  `AddressBook` (the pre-2016 name), not `Contacts`. Our
  `tccutil reset` invocation in the "Reset & Re-request" button
  now uses the correct service name, so the reset actually clears
  the cached deny and re-presents the system prompt.

- **Contacts permission: self-service recovery from the
  "denied-but-invisible-in-System-Settings" stalemate.** Two changes:
    1. `ContactsResolver.requestAccess` no longer short-circuits when
       the current status is `.denied`/`.restricted`. It now always
       invokes `CNContactStore.requestAccess`, which is the *only*
       call that causes macOS to register the app in System Settings
       → Privacy & Security → Contacts. Previously, users who
       declined the first prompt (or who inherited a stale TCC entry
       from a prior signed build) had no path back: our UI said
       "denied" but the Privacy pane had no toggle for the app.
    2. A new "Reset & Re-request" button in the Contacts section of
       Settings shells out to `/usr/bin/tccutil reset Contacts
       <bundle-id>` (no sudo needed for user-owned apps) and
       immediately re-invokes `requestAccess`. This recovers the
       "denied + missing from Privacy pane" state in one click —
       useful when two builds of the same bundle ID coexist on the
       system (e.g. a dev binary in the project folder alongside the
       notarized DMG in /Applications) and confuse TCC's signature
       matcher.

## [0.1.0] — 2026-06-08

### Fixed

- **`callback_url` and absolute attachment URLs now populated
  immediately at boot in named-tunnel mode.** Previously
  `TunnelManager.publicURL` was only set after `cloudflared` printed
  `Registered tunnel connection` on stderr — typically 3-10 seconds
  into bootstrap. Any iMessage event that arrived in that window was
  encoded with `"callback_url": ""` and an `attachments[].url_path`
  but no absolute `attachments[].url`, breaking remote receivers
  that needed to fetch the bytes through the tunnel.

  In named mode the public URL is fully determined by config (the
  user-configured `tunnelHostname`), so we can populate it
  synchronously when `start()` is called — before cloudflared even
  spawns. The existing stderr "Registered tunnel connection"
  extractor remains wired up but becomes a no-op confirmation in
  named mode (its `guard firstTime` short-circuits because
  `publicURL` already matches). Quick mode is unchanged — the
  random `*.trycloudflare.com` URL is genuinely unknown until
  cloudflared prints it.

  Verified live on `imsg.misc.sh`: `GET /status` returns
  `tunnel_url: "https://imsg.misc.sh"` within 2 seconds of app
  launch (was previously empty for the full 3-10s bootstrap window).

### Changed

- **Message text now substitutes a friendly token for `U+FFFC`.**
  iMessage uses the Unicode OBJECT REPLACEMENT CHARACTER as the body
  of any message whose content isn't text (attachments, stickers,
  embedded link previews, etc). Previously the relay forwarded that
  placeholder verbatim, so webhook receivers got `"text": "\ufffc"`
  on attachment messages and `"reply_to_text": "\ufffc"` when
  replying to one — they had to know the convention to handle it.

  Now `ImsgClient.encode(_:)` runs both fields through a
  `friendlyMessageText(_:)` helper that strips `U+FFFC` (and
  surrounding whitespace) and substitutes the literal string
  `[attachment]` when the result is empty. A real caption like
  `"check this out 📎"` passes through unchanged; an attachment with
  no caption becomes `"[attachment]"`.

  Applied to both inbound event payloads and the bulk REST encoders
  (`/history`, `/search/messages`), so MCP clients calling
  `imsg_get_history` see the same friendly form.

### Added

- **Sparkle auto-update release pipeline.** The release workflow now
  signs each release artifact with an ED25519 keypair and updates
  `appcast.xml` on every tag push, so existing installs auto-detect
  new versions on their next poll.

  New pieces:

  - `scripts/sparkle-keygen.sh` — one-time keypair generator. Runs
    Sparkle's `generate_keys` and writes the two halves into
    `build/sparkle-keys/` (gitignored). Maintainer pastes them into
    `SPARKLE_ED_PUBLIC_KEY` / `SPARKLE_ED_PRIVATE_KEY` secrets.
  - `scripts/appcast-add.sh` — invoked by CI after notarization;
    signs the release ZIP via Sparkle's `sign_update` and prepends a
    fresh `<item>` block to `appcast.xml` using a small Python xml
    edit (idempotent on re-run).
  - `appcast.xml` — bootstrap RSS+Sparkle feed at the repo root,
    pointed at by `SUFeedURL` in Info.plist. CI commits new entries
    here automatically.
  - `create-app-bundle.sh` now reads `SPARKLE_ED_PUBLIC_KEY` from the
    environment and injects it into Info.plist's `SUPublicEDKey`. So
    local dev builds boot with the updater disabled (the existing
    "skip Sparkle if key is empty" code path), and CI builds boot
    with the verifier wired in.
  - `.github/workflows/release.yml` gets a new `appcast` job that
    runs after `release`. It downloads the release artifacts,
    rebuilds Sparkle helpers, runs `appcast-add.sh`, and pushes the
    updated `appcast.xml` back to `main`.
  - `docs/DISTRIBUTION.md` — one-stop guide for the maintainer's
    one-time Apple Developer ID + Sparkle setup, the list of GitHub
    secrets required, and the steps to publish + verify a release.

  See [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) for the full
  walkthrough. The release workflow gracefully no-ops the appcast
  job when `SPARKLE_ED_PRIVATE_KEY` isn't set, so the workflow
  still works on forks that haven't done the one-time setup.

- **Contacts framework integration.** When the user grants the new
  Contacts permission, inbound events (`message.received`,
  `message.sent`, `message.reaction`) carry a `data.sender_name`
  (and `data.reply_to_sender_name` for replies) resolved from the
  local Contacts database. The same enrichment shows up on
  `GET /history` and `GET /search/messages` responses, so the
  `imsg_get_history` / `imsg_search_messages` MCP tools surface
  contact names too without any extra plumbing.

  A new `ContactsResolver` (in `Sources/Contacts/`) wraps
  `CNContactStore.unifiedContacts(matching:)` with a thread-safe
  in-memory cache. Lookups normalize phone numbers via the system's
  `CNPhoneNumber` predicate (handles E.164 vs national formatting
  transparently). The cache is auto-invalidated on
  `CNContactStoreDidChange`, so adding a name for a previously-
  unknown handle picks up on the next event.

  Because the relay is `LSUIElement = true`, TCC will not show its
  permission dialog without foreground activation. So instead of
  auto-prompting at boot (which would silently deny and cache that
  deny forever), there's a new **Contacts** section in the General
  Settings tab with a "Grant Access" button that activates the app
  via `NSApp.activate(ignoringOtherApps: true)` before calling
  `requestAccess()`. After a deny it links straight to System
  Settings → Privacy & Security → Contacts. `NSContactsUsageDescription`
  has been in Info.plist all along; it's now actually used.

- **MCP testing recipes.** `TESTING.md` now has:
  - A copy-pasteable "exercise every read-only tool" block that calls
    `imsg_get_status`, `imsg_list_chats`, `imsg_get_chat`,
    `imsg_get_history`, `imsg_search_messages` through the tunnel.
  - A spelled-out FDA gotcha for stdio MCP: the binary inherits the
    TCC profile of whatever spawns it, so when Claude Desktop is the
    parent, you have to grant FDA to **Claude Desktop.app** — the
    menu bar app's FDA grant does not transfer.
  - A pointer to `examples/claude_desktop_config.json`, a one-file
    template you can drop straight into Claude's config directory.

  The HTTP MCP transport sidesteps the FDA-twice issue entirely (the
  menu bar app reads `chat.db` once, then exposes JSON over the
  tunnel), so we now recommend HTTP MCP as the default for any remote
  agent and reserve stdio mode for "Claude Desktop on the same Mac".

- **Outbound attachments via REST and MCP.** Two new surfaces close
  the loop on the attachment story (we already streamed inbound
  attachments out via `/attachments/:msg_id/:index`):

  - `POST /send/attachment?to=&filename=&text=&chat_id=&service=` —
    raw file bytes go in the request body, metadata in the query
    string. No multipart parser required; you can pipe any file
    straight from disk with `curl --data-binary @file`. Cap is 100 MB
    per request (beyond that Messages.app starts misbehaving without
    iCloud-share fallback, so we reject early).
  - `imsg_send_attachment` MCP tool now accepts a
    `content_base64` + `filename` shape in addition to the legacy
    `attachment_path`. That makes the tool actually usable over HTTP
    MCP, where the remote agent has no view of the host Mac's file
    system. Stdio MCP clients can keep using `attachment_path` as
    before.

  Both paths share the same staging directory
  (`~/Library/Application Support/imsg-relay/outbound/<uuid8>-<name>`)
  and the same filename sanitizer (alphanumerics + `.-_()[]+ ` only,
  collapses path traversal, falls back to `attachment-<uuid>` on
  pathological inputs). The staged file is deleted in a `defer` block
  the moment Messages.app's AppleScript send returns, so the directory
  stays empty between sends.

### Fixed

- **Named-mode tunnel start was silently broken by argv ordering.**
  `cloudflared tunnel run --no-autoupdate --token <token>` is rejected
  by `cloudflared` because `--no-autoupdate` is a `tunnel`-level flag,
  not a `run`-subcommand flag. Result: cloudflared printed help and
  exited cleanly (status 0) within ~40ms, leaving no trace in our
  tunnel logs and no `cloudflared` process running. The connector
  would never register, the named tunnel would stay `Inactive` on the
  CF dashboard, and `https://<hostname>` would return CF error 1033.
  Reordered to `tunnel --no-autoupdate run --token <token>` —
  cloudflared now reaches the connection step normally.

### Added

- **Tunnel diagnostic logging.** `TunnelManager.start()` now logs at
  every state transition: `start()` entry (with mode), binary path,
  redacted argv, child PID, every line of cloudflared's stderr (at
  debug level), the first matching URL/ready signal, and the child's
  termination status + reason. Combined with the cleaner
  `stop()` (which now escalates to `SIGKILL` after a 3-second
  `SIGTERM` grace period and waits for reaping before returning),
  diagnosing tunnel issues no longer requires guesswork about
  whether cloudflared even spawned. Run:

  ```bash
  log show --predicate 'subsystem == "com.imsg-relay.app" && category == "tunnel"' \
    --info --debug --last 5m
  ```

  to see the full trace. The argv log redacts the token as
  `<redacted-token-N-chars>` so it never hits the system log even
  at debug verbosity.

- **App icon updated.** New 1024×1024 macOS app icon (green squircle
  with the chat-bubble + `</>` mark matching the menu bar
  template), generated as a complete `.icns` with all 10 required
  sizes (16/32/128/256/512 at 1x and 2x). Replaces the placeholder.

### Changed

- **Named-tunnel docs + Settings UX rewritten to make the
  CF dashboard steps impossible to miss.** The connector token alone
  doesn't authorize the app to create DNS records or change tunnel
  ingress rules — that's a deliberate CF credential split that bit
  the initial setup flow. To address it without expanding the app's
  privilege surface:
  - README's "Setting up a named tunnel" section restructured with
    an explicit prerequisite checklist, a callout explaining *why*
    the dashboard steps are necessary (the credential split), each
    of the 5 steps now annotated with "what happens here", and a
    `dig`/`curl` verification recipe at the end.
  - Settings UI in named mode now shows an inline pre-flight panel
    above the token + hostname fields, walking through the three
    dashboard steps with the "this is where DNS gets created" line
    highlighted, and direct links to the CF dashboard + the full
    README walkthrough.
  - TROUBLESHOOTING gains a top-billed entry for the exact symptom
    ("I pasted token + hostname but `dig` returns nothing") with a
    60-second fix recipe.

### Added

- **Named Cloudflare Tunnel mode.** Settings → Network → Cloudflare
  Tunnel now has a **Mode** picker with two options:
  - **Free (`trycloudflare.com`)** — current behavior, ephemeral URL,
    no CF account required. Default. Right choice for code-based
    webhook receivers that read `server.callback_url` out of every
    event.
  - **Named (your own domain)** — runs `cloudflared tunnel run
    --token <token>` against a connector configured in the user's
    Cloudflare Zero Trust dashboard. The hostname is stable, so MCP
    clients that hardcode the server URL keep working across restarts.
    Requires the connector token and the public hostname (e.g.
    `mcp.yourcompany.com`) to be entered in Settings.

  Implementation:
  - `TunnelMode` enum on `AppConfig` with `.quick` / `.named` cases.
  - New `AppConfig.tunnelToken` (rendered as `SecureField`) and
    `tunnelHostname` fields, both with backwards-compatible decoding
    so existing installs migrate seamlessly.
  - `TunnelManager.start(port:)` builds a per-mode `Runtime` struct
    (arguments + stderr extractor) and runs cloudflared accordingly.
    Quick mode parses `*.trycloudflare.com` out of stderr; named mode
    watches for `Registered tunnel connection` and surfaces
    `https://<hostname>` as the public URL.
  - `AppDelegate.configChanged` keeps a `TunnelConfigSnapshot` so it
    only bounces the tunnel when something tunnel-relevant changed
    (enabled flag, mode, token, hostname, or local API port), not on
    every Save.
  - Hostname normalization strips an optional `http://` or `https://`
    prefix and trailing slashes so users can paste either form.
  - Named-mode misconfiguration (token or hostname empty) shows a
    friendly warning alert with an "Open Settings" button.

- **Attachment relay.** Inbound events whose `attachments_count > 0`
  now carry an `attachments` array with per-file metadata
  (`filename`, `mime_type`, `served_mime_type`, `uti`, `size`,
  `is_sticker`, `missing`) plus a `url` (absolute, through the tunnel
  when up) and `url_path` (relative). A new `GET /attachments/:message_id/:index`
  endpoint on the local Hummingbird server streams the bytes with the
  right `Content-Type` and `Content-Disposition` headers, behind the
  existing bearer-auth middleware. Defensive: the resolved file must
  live under `~/Library/Messages/Attachments/`, otherwise 404 —
  guarding against any upstream path-resolution drift.
- **"Backfill missed messages on restart" toggle** in Settings →
  Inbound stream. Default off — only messages that arrive after the
  app launches are relayed. When on, the watcher resumes from the last
  delivered `ROWID` so messages received while the app was offline get
  relayed at restart. Avoids dumping multi-day history to the user's
  endpoint after a long quit period.
- **MCP HTTP transport.** The menu bar app now exposes the full MCP tool
  surface over `POST /mcp` on the local Hummingbird server (and therefore
  through the Cloudflare Tunnel for remote agents). Built on the official
  `modelcontextprotocol/swift-sdk` `StatelessHTTPServerTransport` — no
  custom transport, no waiting on upstream. Same seven tools regardless
  of transport, bearer-auth protected.
- **`Cmd+V` / `Cmd+C` / `Cmd+X` / `Cmd+A` / `Cmd+Z` keybindings in
  Settings.** `NSApp.mainMenu` is now populated with App + Edit submenus
  so text fields route standard editing shortcuts through the responder
  chain — a classic `LSUIElement` gotcha that silently breaks paste in
  menu-bar-only apps.
- **Save feedback.** Green "✓ Saved" indicator appears in the Settings
  save bar when the user clicks Save, fades after 1.8 seconds.
- **"Clear N dead events" menu item** in the menu bar, shown only when
  there are dead events to clear. Backed by a new `RelayQueue.clearDead()`.
- **README** (replaces PRD as the user-facing entry point). Covers
  install, configure, event protocol, REST API, MCP integration, system
  architecture, permissions, status table, roadmap, and dev workflow.
- **TESTING.md** — manual QA playbook for verifying every surface.
- **docs/ARCHITECTURE.md** — technical deep-dive on the concurrency
  model, process modes, lifecycle, and data flow.
- **docs/TROUBLESHOOTING.md** — known issues and recovery steps.

### Changed

- **App display name** is now **"iMessage Relay"** (was `imsg-relay`).
  Bundle filename is `iMessage Relay.app`. Internal identifiers
  (`CFBundleIdentifier=com.imsg-relay.app`, `CFBundleExecutable=ImsgRelay`,
  App Support directory, MCP server name) are unchanged so any installed
  bundle upgrades cleanly.
- **`MCPService` now accepts an injected `any Transport`** instead of
  hardcoding `StdioTransport`. `main.swift --mcp` passes `StdioTransport()`
  explicitly; `AppDelegate.bootRuntime` builds a
  `StatelessHTTPServerTransport` with `OriginValidator.disabled` and
  boots a second `MCPService` instance on it in a background `Task`.
- **`LocalAPIServer.init` takes an optional `StatelessHTTPServerTransport`.**
  When supplied, it adds a `POST /mcp` route that adapts Hummingbird
  `Request` to `MCP.HTTPRequest` and back. Bearer-auth middleware
  applies uniformly.
- **Settings window** rebuilt around `.formStyle(.grouped)` with
  `LabeledContent` rows, sticky save bar, live Cloudflare Tunnel row
  (ProgressView → URL + Copy button), and `TextField` + `Stepper` combos
  for port fields with `.number.grouping(.never)` formatting and
  out-of-range `onChange` clamping.
- **Tab padding & frame** moved to the `TabView` itself (`padding(20)` +
  `frame(620 × 540)`) so groups have breathing room from the window edge
  without doubling padding inside grouped forms.
- **Menu bar icon and app icon** sourced from designer assets in
  `assets/`; generated at build time into 22 / 44 / 66 PNGs (template)
  and a 10-resolution `AppIcon.icns`.

### Fixed

- **First-launch chat.db backfill.** `ImsgClient.primeCursor()`
  now opens `~/Library/Messages/chat.db` read-only and stores
  `MAX(ROWID)` as the watch cursor before the watcher stream starts.
  Default behavior re-primes on every launch unless the new
  `backfillOnRestart` setting is on. Previously, with no cursor, the
  watcher replayed every historical message in chat.db (tens of
  thousands of events).
- **Dead-event buildup during initial setup.** `HTTPRelay.loop()` now
  short-circuits when `serverEndpoint` is empty — it sleeps three
  seconds without ever calling `dueEvents()` or `markFailed()`. Events
  stay queued and drain the moment a real endpoint is configured.
  Previously, idling without an endpoint would mark every queued event
  failed in a tight loop, parking them all as `dead` within ~10 minutes.
- **Fatal "authorization denied" alert at boot.** `bootRuntime()` now
  probes Full Disk Access via `Permissions.hasFullDiskAccess()` before
  constructing `ImsgClient`. When missing, a friendly retry-able prompt
  links to the right System Settings pane and a 2-second background
  `Timer` auto-resumes boot the moment FDA is granted — no need to
  click "Try Again".
- **Re-presenting alert on "Open Settings…" click.** Replaced the
  recursive `DispatchQueue.main.async` self-call with the quiet
  background timer poll. The discarded timer block parameter avoids
  a `SendingRisksDataRace` warning.
- **`SettingsView` orphan section labels.** Switched to grouped form
  style with `LabeledContent`; sections render with proper macOS
  System Settings spacing now.
- **Port "7,878" formatting.** `TextField` uses `.number.grouping(.never)`.
- **Out-of-range pasted port values.** `.onChange` clamps to the valid
  port range.
- **Stale `relay.sqlite3` (2.2 MB WAL) from prior debug runs.** One-time
  wipe documented in `TESTING.md` and `docs/TROUBLESHOOTING.md`.

### Security

- **No `Origin` header validation on the MCP HTTP transport.** Disabled
  via `OriginValidator.disabled` because tunnel traffic legitimately
  arrives from arbitrary external clients. The bearer-token middleware
  is the auth gate. Origin checks would be belt-and-suspenders against
  a threat model the tunnel doesn't have.
- **All HTTP routes (`/health`, `/status`, `/stats`, `/chats`,
  `/chats/:id`, `/history`, `/search/messages`, `/send`, `/mcp`) sit
  behind the same bearer-auth middleware.** When `bearerToken` is
  empty, auth is open (intended for first-launch UX before the user
  configures the relay).

---

## [0.1.0] — initial implementation

The first end-to-end slice that turns a Mac into a programmable iMessage
gateway. Everything from project bootstrap through a signed installable
`.app` bundle, with:

- **SwiftPM** (no Xcode project, no `.xcodeproj` to merge-conflict on)
- **AppKit menu bar app** with **SwiftUI Settings** window
- **IMsgCore** integrated as a SwiftPM library dependency (not subprocess)
- **MessageStore / MessageWatcher / MessageSender** wired through
  an `ImsgClient` actor
- **SQLite WAL retry queue** with exponential backoff, cursor persistence,
  and dead-letter parking
- **Hummingbird** local HTTP API: `/health`, `/status`, `/stats`,
  `/chats`, `/chats/:id`, `/history`, `/search/messages`, `/send`,
  all behind bearer-auth middleware
- **MCP stdio server** (`ImsgRelay --mcp`) using
  `modelcontextprotocol/swift-sdk`, exposing seven tools:
  `imsg_list_chats`, `imsg_get_chat`, `imsg_get_history`,
  `imsg_search_messages`, `imsg_send_message`, `imsg_send_attachment`,
  `imsg_get_status`
- **Cloudflare Tunnel** supervisor — runs `cloudflared tunnel --url ...`
  as a child process, parses the URL out of stderr, surfaces it
  reactively to the Settings UI and on every relayed event
- **Outbound event relay** with `EventEnvelope` types covering message
  lifecycle (`message.received`, `message.sent`, `message.reaction`),
  tunnel lifecycle (`tunnel.connected`, `tunnel.disconnected`,
  `tunnel.changed`), and relay lifecycle (`relay.started`, `relay.stopped`)
- **Sparkle 2.x auto-update integration**, gated on a real
  `SUPublicEDKey` so dev builds don't crash
- **Developer ID signing + entitlements**:
  `com.apple.security.automation.apple-events` for AppleScript send,
  `com.apple.security.personal-information.contacts` for name resolution,
  hardened runtime, network client/server
- **`create-app-bundle.sh`** + **Makefile**: clean `make app` produces
  a signed bundle from a single command, no Xcode
- **GitHub Actions release pipeline** (matrix arm64 + x86_64, code-sign,
  notarize, DMG + ZIP + SHA-256, tag-triggered)
- **Strict Swift 6 concurrency** throughout (`Sendable`, `@MainActor`,
  `nonisolated`, actors for I/O surfaces)

---

[Unreleased]: https://github.com/ranaroussi/imsg-relay/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ranaroussi/imsg-relay/releases/tag/v0.1.0
