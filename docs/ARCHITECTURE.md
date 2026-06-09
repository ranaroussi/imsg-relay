# Architecture

A technical deep-dive into how iMessage Relay is wired together.

If you're trying to **use** the app, see [`README.md`](../README.md).
If you're trying to **test** it, see [`TESTING.md`](../TESTING.md).
If something's misbehaving, see [`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

---

## 1. Top-level shape

iMessage Relay is a single binary, `ImsgRelay`, that runs in two
mutually exclusive **process modes**:

| Mode | Invocation | What's loaded |
|------|------------|--------------|
| **Menu bar app** | `open "iMessage Relay.app"` (default) | `NSApplicationMain` → `AppDelegate` → menu bar UI, Hummingbird REST API, HTTP MCP transport, Cloudflare Tunnel supervisor, outbound HTTP relay |
| **Stdio MCP server** | `ImsgRelay --mcp` | Bypasses AppKit entirely. Boots `ImsgClient` and a single `MCPService` on `StdioTransport`. No GUI, no menu bar, no event relay, no Hummingbird. |

This split lives in [`src/Sources/main.swift`](../src/Sources/main.swift):
the `--mcp` branch runs synchronously on a `DispatchSemaphore` so stdio
stays line-oriented, while the default branch hands off to
`NSApplicationMain`.

The two modes are intentional: AppKit subtly steals `stdin`/`stdout`
in ways the MCP SDK doesn't like, so Claude Desktop spawning the binary
with `--mcp` always gets a clean stdio surface.

---

## 2. Layout

```
src/Sources/
├── main.swift               # Entry point + mode switch
├── AppDelegate.swift        # Menu bar UI, runtime wiring, permission flow
├── AppConfig.swift          # UserDefaults-backed config store
├── Permissions.swift        # FDA probe + System Settings deep link
├── Log.swift                # os.Logger categories
│
├── Imsg/
│   └── ImsgClient.swift     # Actor wrapping IMsgCore (watcher, sender, store)
│
├── Relay/
│   ├── EventEnvelope.swift  # Outbound event types + envelope struct
│   ├── RelayQueue.swift     # SQLite WAL queue (events + cursors)
│   └── HTTPRelay.swift      # Actor draining the queue with exp backoff
│
├── Tunnel/
│   ├── TunnelManager.swift  # cloudflared subprocess supervisor
│   └── TunnelStatus.swift   # @MainActor ObservableObject for SwiftUI
│
├── API/
│   └── LocalAPIServer.swift # Hummingbird routes + bearer auth + /mcp adapter
│
├── MCP/
│   └── MCPServer.swift      # MCPService — wraps SDK Server, registers tools
│
├── Settings/
│   └── SettingsView.swift   # SwiftUI Settings window
│
└── Resources/               # Icons, etc.
```

---

## 3. Concurrency model

Swift 6 strict concurrency throughout — `swiftSettings:
[.enableUpcomingFeature("StrictConcurrency")]` in `Package.swift`.

| Isolation | Owners |
|-----------|--------|
| `@MainActor` | `AppDelegate`, `MCPService`, `TunnelStatus`, all SwiftUI |
| `actor` | `ImsgClient`, `HTTPRelay`, `StatelessHTTPServerTransport` (from SDK), `StdioTransport` (from SDK) |
| `final class @unchecked Sendable` | `LocalAPIServer` (HBR captures it across the detached server task; we audit by convention), `RelayQueue` (internal `DispatchQueue` for SQLite serialization) |
| `final class` (no isolation, `nonisolated(unsafe)` weak refs) | `TunnelManager` (process supervisor — touched from a child reader task and from the main UI), commented `nonisolated(unsafe)` for the surface that's read concurrently |
| `nonisolated` static helpers | All argument-extraction helpers in `MCPService` — `intArg`, `stringArg`, `utf8`, etc. — so the SDK's tool handler closure (which runs outside the main actor) can call them without an actor hop |
| `Sendable` | `EventEnvelope`, `AppConfig`, all transferred values |

The pattern is: **I/O surfaces are actors, UI is `@MainActor`, the
connecting glue is `@MainActor` (`AppDelegate`) and explicit `Task`s
shuttle data between them.**

---

## 4. Boot sequence

```
NSApplicationMain
   │
   ▼
AppDelegate.applicationDidFinishLaunching
   │
   ├── installMainMenu()          → NSApp.mainMenu (App + Edit submenus)
   ├── setupMenuBar()             → NSStatusItem + initial menu
   └── bootRuntime()
        │
        ├── Permissions.hasFullDiskAccess()?
        │      │
        │      └── NO → presentFullDiskAccessNeeded()
        │              │
        │              ├── show alert with "Open Privacy Settings…" / "Try Again" / "Quit"
        │              ├── start permissionPollTimer (2s interval) ──┐
        │              └── return — boot stays paused                │
        │                                                           │
        │      YES ◄──── poll fires, FDA detected ◄─────────────────┘
        │
        ├── RelayQueue()              # opens ~/Library/Application Support/imsg-relay/relay.sqlite3
        ├── TunnelManager()
        ├── HTTPRelay(queue:, tunnel:)
        ├── ImsgClient(queue:, relay:) — opens chat.db read-only via IMsgCore
        ├── tunnel.attach(relay:)     # so tunnel lifecycle events get enqueued
        │
        ├── StatelessHTTPServerTransport(validationPipeline: ...)
        ├── MCPService(imsg:, transport: <http transport>)
        │
        ├── LocalAPIServer(port:, imsg:, tunnel:, queue:, mcpTransport: <http transport>)
        │
        ├── Task { await relay.start() }           # background event drainer
        ├── Task { await imsg.startWatching() }    # background chat.db watcher
        ├── mcpTask = Task { try await mcp.run() } # SDK Server bound to HTTP transport
        ├── api.start()                            # Hummingbird detached task
        ├── relay.relay(type: .relayStarted, ...)  # boot beacon
        │
        └── if config.tunnelEnabled { startTunnel() }
```

The FDA probe is **before** any IMsgCore construction. A previous
revision let IMsgCore throw `authorization denied` and bubbled it up as
a fatal alert — replaced because it was hostile UX. Now the friendly
prompt is the only failure path users see.

---

## 5. Inbound message flow (chat.db → your endpoint)

```
   Messages.app
        │ (writes)
        ▼
~/Library/Messages/chat.db
        │ (read + watch)
        ▼
IMsgCore.MessageWatcher.stream(sinceRowID: cursor)
        │
        ▼  AsyncStream<Message>
ImsgClient.handle(message:)
        │
        ├── queue.setCursor("imsg-relay.watch-cursor", String(message.rowID))
        │
        ├── if message.isReaction && !includeReactions → drop
        │
        ├── if message.isFromMe → emit .messageSent
        │   else                → emit .messageReceived
        │
        └── HTTPRelay.relay(type:, payload:)
            │
            ├── Build EventEnvelope (with server.identifier,
            │                        endpoint, callback_url from tunnel)
            ├── JSONEncoder
            └── RelayQueue.enqueue(envelope)
                       │
                       ▼
               SQLite events table:
                  (id, type, payload_json, attempts, next_attempt_at, state)
                       │
                       │ (loop drains)
                       ▼
HTTPRelay.loop()
   │
   ├── if config.serverEndpoint.isEmpty → sleep 3s, continue
   │
   ├── queue.dueEvents(limit: 8)
   │
   └── for each: deliver(event)
         │
         ├── URLSession POST to config.serverEndpoint
         │     with "Authorization: Bearer <token>" if configured
         │
         ├── 2xx → queue.markDelivered(id) → row dropped
         │
         ├── 5xx / 429 → queue.markFailed(id, attempts: n + 1)
         │     │
         │     └── next_attempt_at = now + min(60, 2^n) + jitter
         │
         └── other 4xx → queue.markFailed(id, attempts: maxAttempts)
                          (parks immediately as 'dead')
```

### Cursor priming policy

The cursor is the watcher's "high-water mark" — only messages with
`ROWID > cursor` get streamed. The policy depends on the user-visible
`AppConfig.backfillOnRestart` flag (Settings → Inbound stream →
"Backfill missed messages on restart"; default off):

| `backfillOnRestart` | Behavior at every launch |
|---------------------|--------------------------|
| `false` (default)   | `ImsgClient.primeCursor()` always re-reads `MAX(ROWID)` from `chat.db` and overwrites the stored cursor. The watcher starts from "now"; anything received while the app was offline is **skipped**. |
| `true`              | If a cursor is already stored, leave it alone — the watcher resumes from the last delivered `ROWID`, replaying messages received during the offline window. If no cursor exists (true first launch), prime to `MAX(ROWID)` the same way. |

In either mode, the cursor is updated on every delivered message in
`handle(message:)`, so toggling the flag at runtime takes effect on
the next restart without losing state.

`primeCursor()` opens `chat.db` read-only with `SQLite.swift` and runs
`SELECT MAX(ROWID) FROM message`. If the query fails (FDA race, no
Messages history, …) we fall back to whatever cursor exists — worst
case is a full backfill on a true first launch, never a crash.

---

## 6. Outbound flow (REST / MCP → Messages.app)

```
Client (curl / Claude Desktop / remote agent)
   │
   │ POST /send  or  MCP tools/call imsg_send_message
   ▼
LocalAPIServer or MCPService
   │
   ▼
ImsgClient.send(to:, text:, chatID:, service:)
   │
   ▼
IMsgCore.MessageSender — drives Messages.app via AppleScript
   │
   ▼
   Messages.app delivers iMessage (or SMS via service: "sms")
```

The first call triggers the macOS Automation → Messages permission
prompt. After grant, sends complete in ~100-500ms.

---

## 7. MCP — two transports, one tool catalog

`MCPService` is transport-agnostic:

```swift
init(imsg: ImsgClient, transport: any Transport) {
    self.imsg = imsg
    self.transport = transport
    self.server = Server(name: "imsg-relay", version: ..., capabilities: ...)
}
func run() async throws {
    await registerTools()
    try await server.start(transport: transport)
    await server.waitUntilCompleted()
}
```

The seven tools are registered once via
`server.withMethodHandler(CallTool.self) { params in ... }` and the
dispatch switch keys on `params.name`.

### Stdio mode (`--mcp`)

```
main.swift --mcp
   ↓
MCPService(imsg:, transport: StdioTransport())
   ↓
SDK reads from stdin, writes to stdout, line-delimited JSON-RPC
```

Lifetime is the process. A semaphore in `main.swift` holds the runloop
until the Task completes.

### HTTP mode (menu bar)

```
AppDelegate.bootRuntime
   ↓
   ├── mcpTransport = StatelessHTTPServerTransport(validationPipeline: ...)
   ├── mcp = MCPService(imsg:, transport: mcpTransport)
   ├── api = LocalAPIServer(... mcpTransport: mcpTransport)
   ├── mcpTask = Task { try await mcp.run() }   # SDK Server bound
   └── api.start()                              # Hummingbird routes alive
```

When a request hits `POST /mcp`:

```
Hummingbird Request
   │
   ▼  LocalAPIServer.makeMCPRequest(req:, body:)
MCP.HTTPRequest { method, headers, body, path }
   │
   ▼
mcpTransport.handleRequest(_:)              [StatelessHTTPServerTransport]
   │
   ├── runs validation pipeline (Accept header, Content-Type, MCP-Protocol-Version)
   ├── classifies JSON-RPC message kind (request / notification / response)
   │
   ├── notification → yield to SDK Server stream → return 202 Accepted
   │
   └── request →
         │
         ├── yield body to SDK Server's message stream
         ├── stash CheckedContinuation keyed by JSON-RPC id
         │
         ▼  (SDK Server picks up the message, dispatches the registered handler)
         ▼
         ▼  Server calls transport.send(responseData)
         ▼
         ├── matches responseData's id against pending continuations
         └── resumes the awaiting handleRequest call with the response bytes
   │
   ▼
MCP.HTTPResponse (.data, .accepted, .error, etc.)
   │
   ▼  LocalAPIServer.makeHummingbirdResponse(from:)
Hummingbird Response
```

### Why stateless, not stateful

The SDK ships both `StatelessHTTPServerTransport` and
`StatefulHTTPServerTransport`. We picked the stateless one because:

1. **No SSE stream needed** — our tools are all request/response. No
   server-initiated push, no subscriptions.
2. **No `MCP-Session-Id` complexity** — simpler client integration
   (e.g. shell scripts with `curl`).
3. **Bearer auth handles identity** — we don't need MCP sessions
   for access control.

When/if we add resources or prompts that benefit from streaming, the
stateful variant slots in by swapping the transport. Tools don't change.

### Why `OriginValidator.disabled`

The SDK's default pipeline includes `OriginValidator.localhost()`, which
matches only `127.0.0.1` / `localhost` Host headers. That blocks all
tunnel traffic. We replace it with `OriginValidator.disabled` and rely
on the bearer-auth middleware (`BearerAuthMiddleware` in
`LocalAPIServer.swift`) for access control.

---

## 8. Cloudflare Tunnel supervision

`TunnelManager` is a process supervisor for `cloudflared`:

```swift
func start(port: Int, onURL: @escaping (String?) -> Void) {
    // Look for cloudflared in:
    //   1. App bundle: Contents/Resources/cloudflared
    //   2. /opt/homebrew/bin/cloudflared
    //   3. /usr/local/bin/cloudflared
    //   4. which cloudflared
    // If none found, present an alert with brew install instructions.
    //
    // Launch:
    //     cloudflared tunnel --url http://127.0.0.1:<port>
    //
    // Parse stderr for "https://....trycloudflare.com"
    // On URL match → publish to TunnelStatus.shared, call onURL, push to relay
}
```

`TunnelStatus.shared` is the `@MainActor ObservableObject` that the
SwiftUI Settings view subscribes to. `TunnelManager` posts updates via
`Task { @MainActor in TunnelStatus.shared.publicURL = url }` at three
lifecycle points: URL detected, process started, process exited.

The tunnel URL is also written into every outbound event's
`server.callback_url` so remote endpoints learn the current address —
useful when the URL rotates.

---

## 9. Settings UI

`SettingsView` is plain SwiftUI on a grouped form style:

```swift
TabView {
    generalForm     // identity, endpoint, bearer, reactions
        .tabItem { Label("General", systemImage: "gear") }
    networkForm     // ports, tunnel toggle, retry config
        .tabItem { Label("Network", systemImage: "network") }
    statusForm      // tunnel URL, queue stats, about
        .tabItem { Label("Status", systemImage: "info.circle") }
}
.padding(20)
.frame(width: 620, height: 540)
```

State lives in `@State private var config: AppConfig = AppConfigStore.shared.current`.
`save()` writes back via `AppConfigStore.shared.update { $0 = config }`,
which notifies `AppConfigStore.didChangeNotification`. `AppDelegate`
observes that notification to restart tunnel / refresh menu / etc.

The save bar uses `@State private var justSaved = false` with a 1.8s
`DispatchQueue.main.asyncAfter` reset and an `.opacity.combined(with:
.scale)` transition for the "✓ Saved" indicator.

---

## 10. Permissions

| Permission | Probe | Trigger |
|------------|-------|---------|
| **Full Disk Access** | `Permissions.hasFullDiskAccess()` — opens `chat.db` via `FileHandle(forReadingFrom:)`, swallows error to a bool | First launch + every boot |
| **Automation → Messages** | Implicit — surfaces when AppleScript `tell application "Messages"` first runs | First outbound send |
| **Contacts** *(optional)* | Implicit when Contacts framework first queried | First handle resolution |

The FDA flow is the only one we own UX for. The other two ride the
default macOS prompts.

`Permissions.openFullDiskAccessSettings()` uses the deep-link URL
`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`
which jumps directly to the right pane in System Settings.

---

## 11. Logging

`os.Logger` categories live in `Log.swift`:

```swift
enum Log {
    static let app    = Logger(subsystem: subsystem, category: "app")
    static let api    = Logger(subsystem: subsystem, category: "api")
    static let queue  = Logger(subsystem: subsystem, category: "queue")
    static let relay  = Logger(subsystem: subsystem, category: "relay")
    static let imsg   = Logger(subsystem: subsystem, category: "imsg")
    static let mcp    = Logger(subsystem: subsystem, category: "mcp")
    static let tunnel = Logger(subsystem: subsystem, category: "tunnel")
}
```

`subsystem = "com.imsg-relay.app"`. Watch them live:

```bash
log stream --predicate 'subsystem == "com.imsg-relay.app"' --info
```

---

## 12. Build pipeline

```
swift build --configuration release
   │
   ▼
create-app-bundle.sh
   │
   ├── mkdir iMessage Relay.app/Contents/{MacOS,Resources,Frameworks}
   ├── cp ImsgRelay → Contents/MacOS/
   ├── cp Info.plist + entitlements
   ├── cp Resources/* (icons, etc.)
   ├── cp Sparkle framework (or stub if not present)
   ├── codesign --deep --options runtime --sign "Developer ID Application: ..."
   └── codesign --verify
```

`Package.swift` declares:

```swift
.executableTarget(
    name: "ImsgRelay",
    dependencies: [
        .product(name: "IMsgCore", package: "imsg"),
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "SQLite", package: "SQLite.swift"),
        .product(name: "Sparkle", package: "Sparkle"),
    ],
    swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
)
```

CI lives in `.github/workflows/release.yml` — matrix build (arm64 +
x86_64), code-sign with `APPLE_DEVELOPER_CERTIFICATE_P12_BASE64`,
notarize via `notarytool`, package DMG via `create-dmg`, ship to GitHub
Releases on tag push.

---

## 13. Why these specific dependencies

| Dependency | Why |
|------------|-----|
| `openclaw/imsg` (IMsgCore) | The hard parts — chat.db reads, watcher debouncing, AppleScript send wrapper. Direct SwiftPM library, not subprocess, so we get native types and no IPC overhead. |
| `Hummingbird` | Lightweight async server, Swift 6 friendly, no ObjC, minimal deps. Picked over Vapor for size and concurrency-model fit. |
| `modelcontextprotocol/swift-sdk` | Official MCP SDK. Ships both stdio and HTTP server transports as of v0.12.x. |
| `SQLite.swift` | Type-safe SQLite, used for both the retry queue and (read-only) the chat.db cursor priming query. |
| `Sparkle` | The standard for macOS auto-updates. ED25519 signature verification. |
| `cloudflared` *(external binary)* | The tunnel. Embedded in `Contents/Resources/cloudflared` in release builds; falls back to brew path in dev. |

---

## 14. Out of scope (intentionally)

The PRD calls iMessage Relay a "dumb edge node". These do **not** live
in this codebase:

- Business logic
- AI / agent orchestration
- CRM integration
- Conversation state machines
- Analytics
- Multi-tenancy
- Workflow builders
- Long-term message storage beyond the queue

Those belong on the **remote server** that consumes our events and uses
our APIs. The relay is a translator, not a brain.
