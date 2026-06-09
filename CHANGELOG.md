# Changelog

All notable changes to **iMessage Relay** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added

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
