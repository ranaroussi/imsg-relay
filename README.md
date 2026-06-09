# iMessage Relay

> Turn any Mac into a programmable iMessage gateway.

iMessage Relay is a native macOS menu bar app that lets a remote service read and send iMessages on your Mac, in real time, without requiring direct access to Apple's infrastructure. The Mac stays the "dumb edge node" — your business logic, AI workflows, CRM, and storage all live on your server.

It exposes three surfaces for remote integration:

- **Outbound event relay** — pushes new messages, sent messages, reactions, and tunnel lifecycle events to your HTTP endpoint with a durable retry queue.
- **Local HTTP API** — REST endpoints for listing chats, fetching history, searching, and sending messages (with optional Cloudflare Tunnel exposure).
- **MCP server** — stdio Model Context Protocol server with seven tools, ready to plug into Claude Desktop or any MCP client.

Built on [`openclaw/imsg`](https://github.com/openclaw/imsg) (specifically its `IMsgCore` SwiftPM library), pure SwiftPM, no Xcode required.

---

## Features

- **Live inbound stream.** Watches `~/Library/Messages/chat.db` via IMsgCore's `MessageWatcher` and pushes a `message.received`, `message.sent`, or `message.reaction` event for every new row.
- **Reliable delivery.** SQLite WAL-backed queue with exponential backoff (capped at 60s, parked as `dead` after configurable max attempts). No message loss across crashes, network outages, or tunnel reconnects.
- **Send via the menu bar's host.** POST a JSON body to `/send` and Messages.app delivers it through the same account you're signed into.
- **MCP server.** Spawn the binary with `--mcp` to serve seven tools (`imsg_list_chats`, `imsg_get_chat`, `imsg_get_history`, `imsg_search_messages`, `imsg_send_message`, `imsg_send_attachment`, `imsg_get_status`) over stdio.
- **Cloudflare Tunnel built in, two modes.** Toggle it on in Settings and pick **Free** (`*.trycloudflare.com`, rotating URL) for zero-setup demos, or **Named** (your own domain via a CF connector token) for a stable hostname that MCP clients can hardcode. The app supervises the `cloudflared` child process either way and surfaces the public URL in the menu bar and in `server.callback_url` on every event.
- **Native macOS UX.** Menu bar icon, friendly Full Disk Access prompt, SwiftUI settings window matching System Settings' grouped form style, Sparkle 2 auto-updates.
- **Signed + notarized.** GitHub Actions builds arm64 + x86_64 DMG/ZIP artifacts with Developer ID signing, notarization, and SHA-256 checksums.

---

## Install

### From a release

1. Download the right DMG for your Mac from [Releases](https://github.com/ranaroussi/imsg-relay/releases):
   - `imsg-relay-arm64.dmg` — Apple Silicon (M1/M2/M3/M4)
   - `imsg-relay-x86_64.dmg` — Intel
2. Mount the DMG and drag **iMessage Relay** to your **Applications** folder.
3. Launch it. The menu bar icon appears in the top-right.
4. On first launch you'll be prompted to grant **Full Disk Access** — required to read `chat.db`. Click *Open Privacy Settings*, drag the app into the list, flip the toggle on. The relay auto-resumes the moment macOS grants access (no need to click *Try Again*).
5. On your first outbound send you'll see a one-time **Automation → Messages** prompt — allow it.
6. (Optional) Grant **Contacts** if you want phone/email handles resolved to names on inbound events.

### From source

Requires Swift 6.0+ (Xcode 16 toolchain or [Swift.org toolchain](https://swift.org/download/)) and macOS 14+.

```bash
git clone https://github.com/ranaroussi/imsg-relay
cd imsg-relay
make app          # builds, code-signs, produces ./iMessage\ Relay.app
make install      # copies to /Applications/
open "/Applications/iMessage Relay.app"
```

Other targets:

```bash
make build        # debug binary at src/.build/debug/ImsgRelay
make release      # release binary at src/.build/release/ImsgRelay
make run          # build .app and launch
make clean        # nuke build artifacts and the .app bundle
make help         # list everything
```

The build pipeline is intentionally just `swift build` + a shell script — no Xcode project, no `.xcworkspace`, no `pbxproj` to merge-conflict on.

---

## Configure

Click the menu bar icon → **Settings…** and fill in:

| Tab | Field | Notes |
|-----|-------|-------|
| General | **Identifier** | Stable string sent as `server.identifier` on every event. Example: `sales`, `support`, `personal`. |
| General | **Endpoint URL** | HTTPS endpoint that receives relayed events. POST JSON. While this is empty, events queue up but no retry counter gets burnt — they drain the moment you save a URL. |
| General | **Bearer token** | Sent as `Authorization: Bearer <token>` on outbound POSTs *and* required on the local HTTP API when set. Leave blank for dev. |
| General | **Include reactions (tapbacks)** | When off, reactions are dropped at the watcher and never enter the queue. |
| Network | **Local API port** | Default `7878`. |
| Network | **MCP port** | Default `7879`. *(Reserved — see "MCP status" below.)* |
| Network | **Enable Cloudflare Tunnel** | Spawns `cloudflared` and reveals the live public URL inline with a copy button. |
| Network | **Tunnel mode** | `Free (trycloudflare.com)` (default, ephemeral URL) or `Named (your own domain)` (stable hostname). See [Tunnel modes](#tunnel-modes). |
| Network | **Tunnel token** | (Named mode only) Cloudflare connector token from the Zero Trust dashboard. Stored as a secret. |
| Network | **Public hostname** | (Named mode only) The DNS name your tunnel routes from, e.g. `mcp.yourcompany.com`. |
| Network | **Max retry attempts** | Default `12`. Each attempt waits `min(60, 2^n) + jitter` seconds. After this many failures an event is parked as `dead`. |

Click **Save**, you'll see a green ✓ Saved confirmation.

If `cloudflared` isn't bundled (dev builds without it in `Contents/Resources/`) the app falls back to `/opt/homebrew/bin/cloudflared`, `/usr/local/bin/cloudflared`, or `which cloudflared` — install via Homebrew if you don't already have it:

```bash
brew install cloudflared
```

### Tunnel modes

iMessage Relay can front the local API + MCP with the Cloudflare edge in two ways. Pick whichever fits your remote endpoint architecture.

| | **Free** (`trycloudflare.com`) | **Named** (custom domain) |
|---|---|---|
| **Underlying command** | `cloudflared tunnel --url http://localhost:<port>` | `cloudflared tunnel run --token <token>` |
| **URL** | Random `*.trycloudflare.com`, **rotates every restart** | Stable hostname you own (e.g. `mcp.yourcompany.com`) |
| **CF account required** | No | Yes (any plan, including free) |
| **Setup time** | Zero | ~3 minutes in the dashboard |
| **Best for** | First-launch demos, code-based webhook receivers that read `server.callback_url` out of every event | MCP clients that hardcode the server URL; any consumer that can't refresh its config dynamically |
| **DNS** | CF assigns | You point a CNAME in your zone at the tunnel (CF auto-creates it from the dashboard) |
| **CF Access policies** | Not available | mTLS, IP allowlists, OAuth/IdP gates — sit in front of the tunnel hostname |

Both modes emit the same `tunnel.connected` / `tunnel.disconnected` / `tunnel.changed` events. The `server.callback_url` on every event always reflects the current public URL — `*.trycloudflare.com` in free mode, `https://<your-hostname>` in named mode.

#### Setting up a named tunnel (one-time)

1. Make sure you have a domain on Cloudflare (any plan).
2. Go to **[Zero Trust dashboard](https://one.dash.cloudflare.com/) → Networks → Tunnels → Create a tunnel**.
3. Pick the **Cloudflared** connector type, name it (e.g. `imsg-relay-my-mac`), and continue.
4. On the **Install and run a connector** step, **copy the long connector token** (starts with `eyJh…`). You don't actually need to run the install command CF shows — iMessage Relay's bundled `cloudflared` will use the token directly.
5. On the **Public Hostnames** step, add a route:
    - **Subdomain:** `mcp` (or whatever you like)
    - **Domain:** pick your CF-managed domain
    - **Service:** `HTTP`
    - **URL:** `localhost:7878` (or whatever your local API port is — must match Settings → Network → Local API port)
6. Save. CF creates the CNAME automatically.
7. In iMessage Relay → Settings → Network → Cloudflare Tunnel:
    - Switch **Mode** to **Named (your own domain)**
    - Paste the **Tunnel token**
    - Paste the **Public hostname** (e.g. `mcp.yourcompany.com` — bare host, no `https://` needed, we add it)
    - Click **Save**

The tunnel will stop and restart automatically when you save. The Settings → Network → Public URL row will show `https://mcp.yourcompany.com` once the connector establishes its four outbound connections to the CF edge (typically 2–5 seconds).

#### Switching modes

Flip the **Mode** picker and click Save. The app stops the running tunnel and starts a new one with the new mode's arguments. Quick mode reverts to the random `*.trycloudflare.com` URL on next start; named mode reuses your configured hostname.

If you select **Named** without entering both a token and hostname, the app shows an alert with a shortcut back to Settings. The tunnel won't try to start until both fields are populated.

#### One tunnel, multiple services

A single named tunnel can route multiple hostnames to different local ports — useful if you run other services alongside iMessage Relay. Add more **Public Hostnames** entries in the CF dashboard pointing at different `localhost:<port>` targets. iMessage Relay itself only cares about the hostname mapped to its API port.

---

## Outbound event protocol

Every relayed event POSTs the following JSON envelope to your endpoint:

```json
{
  "type": "message.received",
  "timestamp": "2026-06-08T22:30:11.482Z",
  "data": { /* per-event payload */ },
  "server": {
    "identifier": "sales",
    "endpoint": "https://your-server.example.com/imessage",
    "callback_url": "https://manufacture-array-foo-bar.trycloudflare.com"
  }
}
```

`server.callback_url` reads live from `TunnelManager` so URL rotations propagate immediately.

Event types (`EventType` enum in `src/Sources/Relay/EventEnvelope.swift`):

- `message.received` / `message.sent` / `message.reaction` — message lifecycle
- `tunnel.connected` / `tunnel.disconnected` / `tunnel.changed` — Cloudflare Tunnel transitions
- `relay.started` / `relay.stopped` — relay lifecycle

Your endpoint should respond `2xx` to confirm delivery. `5xx` and `429` trigger a backoff-and-retry; other `4xx` codes park the event as `dead`.

### Attachments

When a message includes attachments, the event payload carries an `attachments` array alongside the existing `attachments_count`. Each entry is metadata plus a URL pointing at the relay's `GET /attachments/:message_id/:index` endpoint:

```json
{
  "type": "message.received",
  "data": {
    "id": 19592,
    "guid": "11FD445C-...",
    "text": "\uFFFC",
    "attachments_count": 1,
    "attachments": [
      {
        "url":        "https://....trycloudflare.com/attachments/19592/0",
        "url_path":   "/attachments/19592/0",
        "filename":   "IMG_1234.HEIC",
        "mime_type":  "image/heic",
        "served_mime_type": "image/jpeg",
        "uti":        "public.heic",
        "size":       1846291,
        "is_sticker": false,
        "missing":    false
      }
    ]
  },
  "server": { "callback_url": "https://....trycloudflare.com", ... }
}
```

Field reference:

| Field | Meaning |
|-------|---------|
| `url` | Absolute URL through the Cloudflare Tunnel. Present only when the tunnel is running. |
| `url_path` | Always present. Concatenate with `server.callback_url` for the same URL. |
| `filename` | Friendly display name (Messages' `transfer_name`, fallback to internal `filename`). |
| `mime_type` | Original IANA mime type as recorded in chat.db. |
| `served_mime_type` | Present when IMsgCore transcodes for delivery (e.g., HEIC → JPEG). What `url` will actually serve. Omit means "same as `mime_type`". |
| `uti` | Apple uniform type identifier. |
| `size` | Bytes on disk. |
| `is_sticker` | iMessage sticker flag. |
| `missing` | True if chat.db references a file that's been pruned by macOS. The fetch URL will 404. |

`GET /attachments/<id>/<index>` requires the same bearer token as the rest of the local API. The response is the file bytes with `Content-Type` set from `served_mime_type` / `mime_type` and a `Content-Disposition: inline; filename="..."` header so `curl -OJ` and browsers behave nicely. See [Local HTTP API](#local-http-api) below for the route entry.

---

## Local HTTP API

When **Enable Cloudflare Tunnel** is on, the public `*.trycloudflare.com` URL routes to the local Hummingbird server. Set a **Bearer token** in Settings to require `Authorization: Bearer <token>` on every request.

| Method | Path | Description |
|--------|------|-------------|
| `GET`  | `/health` | Liveness probe — returns `{"ok": true}` |
| `GET`  | `/status` | Identifier + endpoint + tunnel state |
| `GET`  | `/stats`  | Queue depth (`{"pending": N, "dead": M}`) |
| `GET`  | `/chats?limit=N` | Recent chats, most-recent first |
| `GET`  | `/chats/:id` | A chat by numeric `id` (includes participants) |
| `GET`  | `/history?chat_id=N&limit=N` | Recent messages for a chat |
| `GET`  | `/search/messages?query=foo&match=contains` | Full-text search |
| `GET`  | `/attachments/:message_id/:index` | Fetch an attachment's bytes by message rowid + zero-based index |
| `POST` | `/send` | Send a text message |
| `POST` | `/mcp`  | MCP JSON-RPC endpoint (see "MCP server" below) |

`POST /send` body:

```json
{
  "to": "+14155550123",
  "text": "Hello from iMessage Relay",
  "service": "auto"
}
```

Pass `chat_id` instead of `to` to send to an existing group. `service` can be `auto`, `imessage`, or `sms`.

---

## MCP server

iMessage Relay speaks MCP over two transports — same tool surface either way. The HTTP transport is the primary path; stdio is preserved for local Claude Desktop.

### HTTP (default, reachable via Cloudflare Tunnel)

The menu bar app boots an MCP server on a `StatelessHTTPServerTransport` (from the official [`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk)) and exposes it as `POST /mcp` on the same Hummingbird server that serves the REST API. With the Cloudflare Tunnel enabled, your remote AI agents reach it through the public URL with the same bearer token you use for the REST API.

> **Picking a tunnel mode for your MCP client:** if your MCP client can re-read the URL out of incoming webhook events (most code-based backends can), the **free** `*.trycloudflare.com` mode is fine — `server.callback_url` on every event always points at the current tunnel. If your MCP client *hardcodes* the server URL (Claude Desktop config, IDE plugins, some agentic frameworks), use **named** mode so the URL stays stable across restarts. See [Tunnel modes](#tunnel-modes).

```bash
curl -sS -X POST "$TUNNEL_URL/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

Calling a tool:

```bash
curl -sS -X POST "$TUNNEL_URL/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "jsonrpc":"2.0",
    "id":2,
    "method":"tools/call",
    "params":{
      "name":"imsg_list_chats",
      "arguments":{"limit":10}
    }
  }'
```

This is the stateless variant of the [MCP Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#streamable-http): one POST per JSON-RPC request, one JSON response back. No SSE, no session header to manage — just bearer auth and a JSON body.

`Origin` header validation is disabled on this transport since tunnel traffic legitimately arrives from arbitrary external clients; the bearer token is what gates access.

### Stdio (for local Claude Desktop)

Run the same binary with `--mcp` to expose MCP over stdin/stdout instead:

```bash
/Applications/iMessage\ Relay.app/Contents/MacOS/ImsgRelay --mcp
```

This bypasses AppKit entirely — pure JSON-RPC, no GUI, no menu bar. Different process mode on the same binary.

Wire it into Claude Desktop's `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "imsg-relay": {
      "command": "/Applications/iMessage Relay.app/Contents/MacOS/ImsgRelay",
      "args": ["--mcp"]
    }
  }
}
```

For remote stdio via SSH:

```bash
#!/usr/bin/env bash
exec ssh -T mac '/Applications/iMessage Relay.app/Contents/MacOS/ImsgRelay --mcp'
```

### Tools exposed

Both transports surface the same seven tools, all backed by the same `ImsgClient`:

- `imsg_list_chats` — recent chats, paged
- `imsg_get_chat` — chat info + participants by id
- `imsg_get_history` — messages for a chat
- `imsg_search_messages` — full-text search
- `imsg_send_message` — text send
- `imsg_send_attachment` — file send
- `imsg_get_status` — config + tunnel state

---

## Architecture

```
                       ┌────────────────────────────────────┐
                       │           Messages.app             │
                       └────────────────────────────────────┘
                                       │
                                       ▼
                              ~/Library/Messages/chat.db
                                       │ (read + watch)
                                       ▼
┌────────────────────────────────────────────────────────────────────────┐
│                          iMessage Relay.app                            │
│                                                                        │
│  AppDelegate ─┬─ ImsgClient (actor)                                    │
│               │     └─ wraps IMsgCore: MessageStore, MessageWatcher,   │
│               │        MessageSender                                   │
│               │                                                        │
│               ├─ RelayQueue (SQLite WAL, cursor + retry table)         │
│               │                                                        │
│               ├─ HTTPRelay (actor) ─── drains queue, exp backoff,      │
│               │                        2xx → delete, 5xx → retry,      │
│               │                        4xx → park                      │
│               │                                                        │
│               ├─ LocalAPIServer (Hummingbird) ─── /health, /chats,     │
│               │                                   /send, ...           │
│               │                                                        │
│               ├─ TunnelManager ─── supervises cloudflared, parses URL  │
│               │                                                        │
│               └─ MCPService (--mcp mode) ─── modelcontextprotocol      │
│                                              swift-sdk, stdio          │
└────────────────────────────────────────────────────────────────────────┘
              │                              │
              ▼                              ▼
       Remote endpoint                Cloudflare Tunnel
        (your server)                       │
                                            ▼
                                   Local HTTP API (Hummingbird)
                                   exposed via *.trycloudflare.com
```

The relay is intentionally a "dumb edge node": no business logic, no analytics, no AI, no multi-tenancy. All that belongs on your remote server.

---

## Permissions

iMessage Relay needs three system grants:

| Permission | Why | When you'll be asked |
|------------|-----|----------------------|
| **Full Disk Access** | Read `~/Library/Messages/chat.db` | First launch — friendly retry-able prompt, auto-resumes once granted |
| **Automation → Messages** | Send via Messages.app | On first outbound send |
| **Contacts** *(optional)* | Resolve handles to names | First time we resolve a contact |

All three prompts come from macOS itself. The app sits idle until they are granted.

---

## Status

| Capability | Status |
|------------|--------|
| Inbound message stream (received / sent / reactions) | ✅ Shipping |
| Outbound `/send` text | ✅ Shipping |
| Outbound `/send/attachment` | 🚧 Tool & MCP path exist, REST multipart endpoint TODO |
| SQLite retry queue with backoff + dead-letter | ✅ Shipping |
| Cloudflare Tunnel supervisor + live URL surfacing | ✅ Shipping |
| MCP stdio server (7 tools) | ✅ Shipping |
| MCP HTTP server transport (tunnel-reachable) | ✅ Shipping (stateless `POST /mcp`) |
| MCP HTTP/SSE streaming + sessions | 🚧 Out of scope for v0 (tools don't need server-initiated push) |
| Sparkle 2 auto-updates | ✅ Wired (needs ED25519 key + appcast.xml in release pipeline) |
| Developer ID signing + notarization | ✅ Local + CI |
| Contacts name resolution on inbound events | 🚧 Stubbed |
| Settings: live tunnel URL with copy | ✅ Shipping |
| Settings: live permissions checklist | 🚧 Static text; no real-time state yet |

---

## Roadmap

- [ ] `POST /send/attachment` multipart endpoint to round out the REST surface
- [ ] Generate + ship Sparkle ED25519 keypair, automate `appcast.xml` publication from the release workflow
- [ ] Contacts framework integration: resolve handles to names on outbound events
- [ ] Settings → Status tab: live permission detection + buttons that jump to each pane
- [ ] Optional named Cloudflare Tunnel (instead of `trycloudflare.com`) for stable URLs
- [ ] Tests target (skipped for the v0 slice to ship faster)

Contributions welcome — open an issue first for anything non-trivial so we can talk through the shape.

---

## Development

```bash
make build      # debug
make release    # release
make app        # .app bundle (ad-hoc signed if no Developer ID found)
make run        # build + launch
make clean      # remove .build and the .app
```

### Project layout

```
imsg-relay/
├── assets/                          # design source files
├── src/
│   ├── Info.plist
│   ├── Package.swift                # Swift 6, macOS 14+
│   └── Sources/
│       ├── main.swift               # --mcp branch + NSApplicationMain
│       ├── AppDelegate.swift        # menu bar, runtime wiring, permission prompt
│       ├── AppConfig.swift          # UserDefaults-backed config store
│       ├── Permissions.swift        # FDA probe + System Settings deep link
│       ├── Log.swift                # os.Logger categories
│       ├── Imsg/ImsgClient.swift    # actor wrapping IMsgCore
│       ├── Relay/                   # EventEnvelope, RelayQueue (SQLite), HTTPRelay (actor)
│       ├── Tunnel/                  # TunnelManager + TunnelStatus (observable)
│       ├── API/LocalAPIServer.swift # Hummingbird routes + bearer auth
│       ├── MCP/MCPServer.swift      # MCP stdio service
│       ├── Settings/SettingsView.swift  # SwiftUI Settings window
│       └── Resources/               # AppIcon.icns, MenuBarIcon{,@2x,@3x}.png
├── .github/workflows/release.yml    # build matrix → notarize → DMG → release
├── create-app-bundle.sh             # SwiftPM build → .app skeleton → sign
├── Makefile
├── entitlements.plist
└── sparkle-entitlements.plist
```

### Release

Tag-based:

```bash
git tag v0.2.0
git push --tags
```

The `.github/workflows/release.yml` workflow then:

1. Builds arm64 + x86_64 in matrix
2. Downloads the right `cloudflared` per arch and embeds it
3. Code-signs with Developer ID (cert from `APPLE_DEVELOPER_CERTIFICATE_P12_BASE64` secret)
4. Notarizes via `notarytool`
5. Packages DMG (with `create-dmg`) + ZIP, both with SHA-256 checksums
6. Cuts a GitHub Release with auto-generated notes

Required secrets in the repo: `APPLE_DEVELOPER_CERTIFICATE_P12_BASE64`, `APPLE_DEVELOPER_CERTIFICATE_PASSWORD`, `APPLE_DEVELOPER_ID_APPLICATION`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_SPECIFIC_PASSWORD`.

---

## Documentation

- [`TESTING.md`](TESTING.md) — manual QA playbook for every surface (REST, MCP stdio, MCP HTTP, tunnel, permissions, settings UX)
- [`CHANGELOG.md`](CHANGELOG.md) — version history
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — technical deep-dive: concurrency model, process modes, lifecycle, data flow, dependency rationale
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — common issues and recovery steps

---

## Credits

- [`openclaw/imsg`](https://github.com/openclaw/imsg) — the heavy lifting (chat.db reads, watcher, AppleScript send surface)
- [Sparkle](https://sparkle-project.org/) — auto-updates
- [Hummingbird](https://github.com/hummingbird-project/hummingbird) — the local HTTP server
- [`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk) — MCP
- [SQLite.swift](https://github.com/stephencelis/SQLite.swift) — the queue & cursor store
- [`cloudflared`](https://github.com/cloudflare/cloudflared) — public URL exposure

## License

MIT
