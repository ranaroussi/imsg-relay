# Changelog

All notable changes to **iMessage Relay** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added

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
