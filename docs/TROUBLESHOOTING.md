# Troubleshooting

Common issues and how to recover. Add to this file whenever you hit
something non-obvious.

---

## Full Disk Access

### "iMessage Relay needs Full Disk Access" prompt won't go away

The app is waiting for FDA on `~/Library/Messages/chat.db`. Steps:

1. Click **Open Privacy Settings…** on the alert.
2. Find **iMessage Relay** in the Full Disk Access list.
   - If it's there with the toggle off → toggle it on.
   - If it's there with the toggle on → toggle off, then on (forces re-grant).
   - If it's not there → click the **+** button and add
     `/Applications/iMessage Relay.app`.
3. Within ~2 seconds the menu bar should auto-resume to the normal
   runtime state. No need to click "Try Again" — the app polls FDA
   every 2 seconds via a background `Timer`.

### FDA was working, then broke after `make app` rebuild

**This is expected.** macOS revokes FDA whenever the binary's code
signature changes, and ad-hoc signing (or self-signed Developer ID
re-keys) qualify. After every `make app` rebuild, you must re-grant
FDA to the new bundle.

Workarounds:

- **Quick re-grant** in System Settings → Privacy & Security → Full
  Disk Access: toggle iMessage Relay off, then back on.
- **Stable signing** with a consistent Developer ID certificate. Set
  `APPLE_DEVELOPER_ID_APPLICATION` env var when running `make app` and
  Apple's signing chain will preserve the FDA grant across rebuilds.

### `tccutil reset SystemPolicyAllFiles com.imsg-relay.app` did nothing

You may need to also reset for the **executable path**, not just the
bundle ID:

```bash
tccutil reset SystemPolicyAllFiles
# Nuclear option — resets for ALL apps; you'll re-prompt for everything
```

---

## Queue stuck / unexpected event counts

### "Queue: 8 pending, 11 dead" right after launch — but I just installed the app

The `relay.sqlite3` queue is **persistent** between launches. Those
events are from prior runs (e.g. during development before an endpoint
was configured, or from a build that had the chat.db backfill bug).

Recovery:

```bash
killall ImsgRelay
rm -f "$HOME/Library/Application Support/imsg-relay/relay.sqlite3"*
open "/Applications/iMessage Relay.app"
```

This deletes the SQLite file + WAL + SHM. A fresh empty queue gets
created on next launch.

Alternatively, click the menu bar's "Clear N dead events" item to
just clear the dead state — pending events remain queued.

### Attachment URL returns 404

Three possible causes, in order of likelihood:

1. **macOS pruned the attachment from disk.** Messages garbage-collects
   old attachments aggressively (especially when "Optimize Mac Storage"
   is on). The chat.db row remains but the file is gone. The event
   payload will have `attachments[i].missing = true` in this case —
   check it before fetching.
2. **Wrong index.** `attachments[0]` and `attachments[1]` are different
   files. Each message can have multiple attachments; the `url_path`
   in the payload is authoritative for which one.
3. **The attachment lives outside `~/Library/Messages/Attachments/`.**
   We refuse to serve anything outside that root as a defensive measure.
   Check the log:

   ```bash
   log show --predicate 'subsystem == "com.imsg-relay.app" && category == "imsg"' \
     --info --last 5m | grep "attachment refused"
   ```

   If this fires, the upstream `imsg` AttachmentResolver is returning a
   path we don't expect — file an issue with the log excerpt.

### Attachment URL returns the wrong content-type

We serve `served_mime_type ?? mime_type`. If the file is a HEIC that
IMsgCore transcoded to JPEG, the URL will deliver `image/jpeg` bytes
even though the original `mime_type` in chat.db is `image/heic`. The
`served_mime_type` field in the event payload tells consumers what
they'll actually get.

### Watcher backfilled chat.db history I didn't expect

Check the **"Backfill missed messages on restart"** toggle in Settings
→ Inbound stream. Default is **off** — only messages received after
the app starts are relayed. If the toggle is on, messages that arrived
while the app was offline get relayed at restart, which surprises
people who quit overnight and come back to a flood.

To switch behaviors at runtime:

1. Settings → Inbound stream → toggle "Backfill missed messages on restart" off
2. Save
3. Restart the app — `primeCursor()` will overwrite the stored cursor
   with the current `MAX(ROWID)`, and only new messages will be relayed
   from that point forward

The decision log line confirms which mode was used:

```bash
log show --predicate 'subsystem == "com.imsg-relay.app" && category == "imsg"' \
  --info --last 5m | grep "cursor primed"
# Expected (default): cursor primed at rowID 12345 (backfillOnRestart=false)
```

If priming logs the right message but you still see historical events,
your stored queue contains residue — see "Queue stuck / unexpected
event counts" above for the SQLite reset.

### Events keep going to "dead" without ever reaching my endpoint

Three things to check:

1. **Endpoint URL set?** Open Settings → General → Endpoint URL. If
   empty, the relay loop short-circuits (sleeps 3s instead of retrying)
   so events stay queued as `pending`, not `dead`. If they're going
   `dead` despite an empty endpoint, you have an old build — rebuild
   from main.
2. **Endpoint returns 5xx / 429?** The loop will retry with exponential
   backoff (capped at 60s) for `maxRetryAttempts` attempts (default 12),
   then mark `dead`. Check your endpoint's logs.
3. **Endpoint returns 4xx?** Anything other than 429 is treated as
   non-retryable and parked as `dead` immediately. Common cause: wrong
   bearer token at the endpoint side, or expecting a different payload
   shape.

To inspect the actual error:

```bash
log show --predicate 'subsystem == "com.imsg-relay.app" && category == "relay"' \
  --info --last 10m
```

---

## Settings UI

### `Cmd+V` doesn't paste into text fields

Was a real bug in pre-v0.1.x builds — `LSUIElement` apps don't get the
standard Edit menu, so `NSText.paste:` had nothing binding `Cmd+V`. The
fix is `installMainMenu()` in `AppDelegate` (App + Edit submenus on
`NSApp.mainMenu`).

If you're on a current build and paste still doesn't work, check that
`installMainMenu()` is being called (it's the first thing in
`applicationDidFinishLaunching` before `setupMenuBar()`).

### Port field accepts "7,878" and breaks the API

Old build. Current build uses `.number.grouping(.never)` so the
formatter rejects grouping separators, and an `.onChange` clamps
out-of-range values back into the valid port range.

### "Saved" indicator doesn't appear when I click Save

Either:
- You're on an old build (the indicator was added in this release), or
- `justSaved` state isn't toggling. Check `SettingsView.swift`'s `save()`
  for the `justSaved = true` line.

If it appears but doesn't fade, the `DispatchQueue.main.asyncAfter`
reset block was deleted. The 1.8s delay is intentional, not animated.

---

## Cloudflare Tunnel

### Tunnel toggle on, but no public URL appears

Possible causes:

1. **`cloudflared` not installed.** The app looks in this order:
   - `App.app/Contents/Resources/cloudflared` (release builds only)
   - `/opt/homebrew/bin/cloudflared`
   - `/usr/local/bin/cloudflared`
   - First match from `which cloudflared`

   In dev builds, the embedded binary isn't shipped. Install via:

   ```bash
   brew install cloudflared
   ```

   Then restart the app or toggle the tunnel switch off and on.

2. **cloudflared launched but stdout/stderr parser missing the URL.**
   Check the tunnel category log:

   ```bash
   log show --predicate 'subsystem == "com.imsg-relay.app" && category == "tunnel"' \
     --info --last 2m
   ```

3. **Network can't reach Cloudflare's edge.** Test directly:

   ```bash
   cloudflared tunnel --url http://127.0.0.1:7878
   ```

### Tunnel URL keeps rotating

`trycloudflare.com` URLs are ephemeral — they change every restart of
the cloudflared process. That's working as designed for free-tunnel
mode. The app handles it gracefully:

- `TunnelStatus.shared.publicURL` updates reactively, Settings UI
  re-renders.
- Every outbound event includes the current URL in
  `server.callback_url`, so code-based webhook receivers always learn
  the latest one.

If your remote endpoint **can't** dynamically follow the rotation
(MCP clients with hardcoded URLs, IDE plugins, agentic frameworks
loading config at boot, etc.), switch to **named tunnel mode**:
Settings → Network → Cloudflare Tunnel → Mode → "Named (your own
domain)". See [Tunnel modes in the README](../README.md#tunnel-modes)
for the CF dashboard setup walkthrough.

### Named tunnel won't connect

You picked **Named** mode in Settings, saved, but the Public URL row
never goes green. Check in this order:

1. **Did you actually paste both fields?** The Settings panel shows
   a yellow warning if either the token or the hostname is empty.
   Both are required. Re-open Settings and confirm.

2. **Is the connector token current?** Token rotations from the CF
   dashboard invalidate the old token immediately. Pull a fresh
   token from **Zero Trust → Networks → Tunnels → your tunnel →
   Configure → Install and run a connector** and re-paste it.

3. **Did you configure a Public Hostname in the dashboard?** A named
   tunnel with no public hostnames will register connections fine
   but won't route any traffic. In the CF dashboard:
   **Tunnels → your tunnel → Public Hostnames → Add a public hostname**.
   Service must be `HTTP` and URL must be `localhost:<port>` where
   `<port>` matches Settings → Network → Local API port.

   **You don't need to pre-create the subdomain DNS record** — CF
   creates the proxied CNAME for you when you save the Public Hostname.
   If CF refuses to auto-create the CNAME with a message like
   *"An A, AAAA, or CNAME record with that host already exists"*,
   you've got a conflict: an existing DNS record, or the subdomain is
   bound to a Worker / Pages site / Email Routing rule. Go to the
   regular CF dashboard → DNS → Records, delete the conflicting
   entry, then re-save the Public Hostname.

4. **Local API port mismatch.** If you change the Local API port in
   Settings, you also need to update the **Service** field on the
   matching Public Hostname in the CF dashboard. cloudflared will
   accept inbound traffic but route it to a port nothing's listening
   on, so the user-visible symptom is "tunnel up, requests time out".

5. **Inspect cloudflared's stderr.** The app surfaces it under the
   `tunnel` category:

   ```bash
   log show --predicate 'subsystem == "com.imsg-relay.app" && category == "tunnel"' \
     --info --last 5m
   ```

   Look for `Registered tunnel connection` (good — you're up) vs.
   `failed to register tunnel: …` (bad — token issue).

6. **Try the same token by hand.** If you have `cloudflared`
   installed on your shell, run:

   ```bash
   cloudflared tunnel run --token <your-token>
   ```

   If that also fails to register, the issue is on the CF side, not
   ours. Check the dashboard for the tunnel's connector status.

### Named tunnel hostname showing `https://https://...`

You pasted the hostname with the scheme included. The app strips an
optional `http://` or `https://` prefix at normalization time, but if
you're still seeing a doubled scheme on `server.callback_url` you may
be on an older build. Repaste as a bare hostname (`mcp.yourcompany.com`)
and Save.

---

## MCP

### Claude Desktop doesn't show the `imsg-relay` server

1. Verify the config file path is `~/Library/Application Support/Claude/claude_desktop_config.json`.
2. Validate JSON:

   ```bash
   python3 -m json.tool < ~/Library/Application\ Support/Claude/claude_desktop_config.json
   ```

3. Verify the `command` path is the executable inside the bundle:

   ```bash
   /Applications/iMessage\ Relay.app/Contents/MacOS/ImsgRelay --mcp < /dev/null
   # Should print an error to stderr and exit cleanly (no stdin → EOF)
   ```

4. **Fully quit** Claude Desktop (not just close the window) and
   relaunch. MCP servers are spawned at app startup.

5. Check Claude's MCP debug log — usually visible in Settings → Developer.

### MCP HTTP `POST /mcp` returns "Not Acceptable: Client must accept application/json"

The `AcceptHeaderValidator` requires an explicit `Accept: application/json`
header. `curl` doesn't set this by default. Add the header:

```bash
curl -sS -X POST http://127.0.0.1:7878/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \         # ← this one
  -H "Authorization: Bearer $TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

### MCP HTTP returns 404 / connection refused

Two layers:

- **Connection refused → app not running, or LocalAPIServer didn't start.**
  Usually because FDA isn't granted, so `bootRuntime` exited at the
  permission probe. Re-grant FDA.

- **404 → path mismatch.** The route is `/mcp` (lowercase, no trailing
  slash). Check the request URL.

### MCP `tools/call` returns "isError: true" with no useful message

Two causes:

1. **Missing required argument.** Each tool has required keys (e.g.,
   `imsg_send_message` needs `to` and `text`). See the tool catalog in
   `MCPServer.swift` or call `tools/list` to see schemas.

2. **The underlying `ImsgClient` call threw.** Common reasons:
   - Sending without Automation → Messages permission (first send only)
   - chat.db query referencing a non-existent chat_id
   - Search query that's empty or whitespace-only

   Check the imsg category log for the underlying error:

   ```bash
   log show --predicate 'subsystem == "com.imsg-relay.app" && category == "imsg"' \
     --info --last 2m
   ```

---

## Crashes / process exits

### App crashes on launch

Check `~/Library/Logs/DiagnosticReports/` for an `ImsgRelay-*.ips`
crash report. Common causes:

- **Code signature mismatch after rebuild without re-signing.** Run
  `make app` cleanly.
- **Missing Sparkle framework in the bundle.** If you cleaned the
  Sparkle dependency, `make app` should re-fetch it; if not, run
  `swift package resolve` from `src/`.
- **Stale `.build` directory across Swift toolchain upgrades.** Nuclear
  reset: `rm -rf src/.build && make app`.

### App quits silently after a few seconds

Almost certainly a Sparkle initialization issue. The app checks
`SUPublicEDKey` and skips Sparkle entirely if missing — make sure that
guard is still in place. Then check the log:

```bash
log show --predicate 'subsystem == "org.sparkle-project.Sparkle"' \
  --info --last 5m
```

### Stdio MCP process exits immediately

Almost always FDA-related. The `--mcp` mode constructs `ImsgClient`,
which opens chat.db. Without FDA on the **invoking process** (e.g., the
Terminal app, or Claude Desktop, or your SSH wrapper), the open fails.

Workaround: ensure the **parent process** that spawns `ImsgRelay --mcp`
has FDA — not just the iMessage Relay app itself.

---

## Logs and diagnostics

### Where to find logs

```bash
# Live stream (Cmd+C to stop)
log stream --predicate 'subsystem == "com.imsg-relay.app"' --info

# Last 5 minutes
log show --predicate 'subsystem == "com.imsg-relay.app"' --info --last 5m

# Per-category
log show --predicate 'subsystem == "com.imsg-relay.app" && category == "relay"' --info --last 5m
log show --predicate 'subsystem == "com.imsg-relay.app" && category == "imsg"' --info --last 5m
log show --predicate 'subsystem == "com.imsg-relay.app" && category == "tunnel"' --info --last 5m
log show --predicate 'subsystem == "com.imsg-relay.app" && category == "mcp"' --info --last 5m
log show --predicate 'subsystem == "com.imsg-relay.app" && category == "api"' --info --last 5m
log show --predicate 'subsystem == "com.imsg-relay.app" && category == "queue"' --info --last 5m
```

### Where state lives

| What | Path |
|------|------|
| Settings | `defaults read com.imsg-relay.app` |
| Queue + cursor | `~/Library/Application Support/imsg-relay/relay.sqlite3` (plus `-wal`, `-shm`) |
| App bundle | `/Applications/iMessage Relay.app` (production) or `./iMessage Relay.app` (dev) |
| Source PNGs | `assets/` |
| Processed icons | `src/Sources/Resources/AppIcon.icns`, `MenuBarIcon*.png` |
| Build artifacts | `src/.build/` (gitignored) |

### Inspecting the queue directly

```bash
DB="$HOME/Library/Application Support/imsg-relay/relay.sqlite3"

# Aggregate counts
sqlite3 "$DB" "SELECT state, COUNT(*) FROM events GROUP BY state"

# Last 20 events
sqlite3 -header "$DB" "SELECT id, type, state, attempts, next_attempt_at \
                       FROM events ORDER BY id DESC LIMIT 20"

# Cursors
sqlite3 -header "$DB" "SELECT * FROM cursors"

# Nuclear reset
sqlite3 "$DB" "DELETE FROM events; DELETE FROM cursors"
```
