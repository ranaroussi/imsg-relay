# Testing iMessage Relay

Manual QA playbook. Each section is independent — skip what you don't need.

If something fails, see [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) first.

---

## Prerequisites

```bash
# 1. Build a fresh signed bundle
make app

# 2. Install it
sudo cp -R "iMessage Relay.app" /Applications/

# 3. Launch
open "/Applications/iMessage Relay.app"

# 4. Grant Full Disk Access in System Settings → Privacy & Security → Full Disk Access
#    The app prompts for this on first launch and auto-resumes the moment FDA is granted.
#    NOTE: macOS revokes FDA whenever the code signature changes. After every
#    `make app` rebuild, you must re-grant FDA to the new bundle (toggle off and on,
#    or remove and re-add the entry).
```

Configure in **Settings…** (menu bar → "Settings…" or `Cmd+,`):

| Field | Recommended value for testing |
|-------|-------------------------------|
| Identifier | `test` |
| Endpoint URL | A webhook receiver, e.g. https://webhook.site/your-uuid |
| Bearer token | `dev-token-1234` (any string) |
| Enable Cloudflare Tunnel | On (for HTTP / MCP HTTP tests) |
| Include reactions | On |
| Backfill missed messages on restart | Off (default) |

Click **Save** — you should see a green ✓ Saved flash for ~1.8s.

---

## 0. Reset state (optional)

Useful between test runs to start with a clean queue:

```bash
# Quit the app
killall ImsgRelay 2>/dev/null

# Wipe the queue + cursor
rm -f "$HOME/Library/Application Support/imsg-relay/relay.sqlite3"*

# Reset settings (optional, also wipes endpoint config)
defaults delete com.imsg-relay.app

# Re-launch
open "/Applications/iMessage Relay.app"
```

---

## 1. Smoke test — app boots and listens

```bash
# Menu bar shows iMessage Relay icon? ✅
# Click it: do you see "Queue: 0 pending, 0 dead"? ✅
# Status bar shows tunnel URL (if tunnel enabled)? ✅

# Local API responding?
curl -sS http://127.0.0.1:7878/health
# Expected: {"ok":true}

# With bearer auth set, unauthenticated request rejected?
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7878/status
# Expected: 401

# Authenticated request works?
curl -sS -H 'Authorization: Bearer dev-token-1234' http://127.0.0.1:7878/status | jq
# Expected: { identifier, endpoint, tunnel_url, tunnel_running }
```

---

## 2. Outbound event relay

Send yourself a message from another device, or have someone iMessage you.

```bash
# Within ~1 second, the menu bar should show "Queue: 1 pending, 0 dead",
# then drop back to 0 pending once the webhook receives the event.

# Check your webhook receiver — you should see a POST with this shape:
{
  "type": "message.received",
  "timestamp": "2026-06-09T...",
  "data": { /* message payload */ },
  "server": {
    "identifier": "test",
    "endpoint": "https://webhook.site/your-uuid",
    "callback_url": "https://....trycloudflare.com"
  }
}
```

**Verifying no historical backfill on first launch:**

```bash
# Wipe state and relaunch
killall ImsgRelay
rm -f "$HOME/Library/Application Support/imsg-relay/relay.sqlite3"*
open "/Applications/iMessage Relay.app"
sleep 5

# Queue should be 0/0. NO historical messages should be relayed.
# Only messages received AFTER launch trigger events.

curl -sS -H 'Authorization: Bearer dev-token-1234' http://127.0.0.1:7878/stats
# Expected: {"queued":0,"dead":0}
```

**Verifying `backfillOnRestart` semantics:**

Default (`Backfill missed messages on restart` = OFF):

```bash
# 1. Launch the app, send yourself a few iMessages, watch them relay.
# 2. Quit the app.
killall ImsgRelay

# 3. Send yourself 2-3 more iMessages while the app is closed.
# 4. Relaunch.
open "/Applications/iMessage Relay.app"
sleep 5

# Queue should be 0/0. Messages sent while offline are NOT relayed.
curl -sS -H 'Authorization: Bearer dev-token-1234' http://127.0.0.1:7878/stats

# Log line confirms: "cursor primed at rowID NNNN (backfillOnRestart=false)"
log show --predicate 'subsystem == "com.imsg-relay.app" && category == "imsg"' \
  --info --last 30s | grep "cursor primed"
```

Toggled on (`Backfill missed messages on restart` = ON):

```bash
# 1. Settings → Inbound stream → enable "Backfill missed messages on restart". Save.
# 2. Quit the app, send yourself a few iMessages, relaunch.
killall ImsgRelay
# (send messages here)
open "/Applications/iMessage Relay.app"
sleep 5

# Queue should drain those missed messages — your webhook receives them.
# Log line confirms: cursor is NOT re-primed (resumes from stored value).
log show --predicate 'subsystem == "com.imsg-relay.app" && category == "imsg"' \
  --info --last 30s | grep -E "cursor primed|watch loop starting"
```

**Verifying graceful behavior without an endpoint:**

```bash
# In Settings, clear the Endpoint URL field. Save.
# Send yourself a message. Queue grows ("3 pending") but no events go dead.
# Set the endpoint back to your webhook. Queue drains within seconds.
```

---

## 3. REST API

All requests with `Authorization: Bearer dev-token-1234`.

```bash
TOKEN="dev-token-1234"
BASE="http://127.0.0.1:7878"
H="-H 'Authorization: Bearer $TOKEN'"
```

```bash
# Health
curl -sS $BASE/health | jq

# Status
curl -sS -H "Authorization: Bearer $TOKEN" $BASE/status | jq

# Stats
curl -sS -H "Authorization: Bearer $TOKEN" $BASE/stats | jq

# List chats
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/chats?limit=10" | jq '.chats | length'

# Pick a chat ID from the list above
CHAT_ID=12345
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/chats/$CHAT_ID" | jq

# History
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/history?chat_id=$CHAT_ID&limit=10" | jq '.messages | length'

# Search
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/search/messages?q=hello&limit=5" | jq

# Send
curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"to":"+15555550123","text":"Hello from iMessage Relay"}' \
  $BASE/send
# Expected: {"queued":true}
# Note: first send triggers an "Automation → Messages" macOS prompt. Allow it.
```

---

## 4. MCP — stdio (local Claude Desktop)

### Raw stdio sanity

```bash
# Launch in --mcp mode, feed an initialize + tools/list, watch the response
printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | "/Applications/iMessage Relay.app/Contents/MacOS/ImsgRelay" --mcp 2>/dev/null

# Expected: two JSON-RPC response lines.
# The second one should list all 7 tools (imsg_list_chats, imsg_get_chat, etc.)
```

### Claude Desktop wiring

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

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

Quit and relaunch Claude Desktop. In a chat, ask:
> "List my five most recent iMessage chats."

Claude should call `imsg_list_chats` and reply with the data. Confirm in
Claude's MCP status panel that `imsg-relay` is connected and all 7 tools
are listed.

---

## 5. MCP — HTTP (remote agents via tunnel)

### Local 127.0.0.1

```bash
TOKEN="dev-token-1234"

# tools/list
curl -sS -X POST http://127.0.0.1:7878/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq

# Expected: { "jsonrpc":"2.0", "id":1, "result":{ "tools":[ ... 7 entries ... ] } }
```

### Calling a tool

```bash
curl -sS -X POST http://127.0.0.1:7878/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "jsonrpc":"2.0",
    "id":2,
    "method":"tools/call",
    "params":{ "name":"imsg_list_chats", "arguments":{"limit":3} }
  }' | jq

# Expected: { "result": { "content": [{"type":"text","text":"...JSON..."}], "isError":false } }
```

### Through the tunnel

```bash
# Read the tunnel URL from the menu bar (or /status)
TUNNEL=$(curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7878/status | jq -r .tunnel_url)
echo "tunnel: $TUNNEL"

curl -sS -X POST "$TUNNEL/mcp" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq

# Should return the same 7 tools.
```

### Auth failures should reject cleanly

```bash
# No bearer
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:7878/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
# Expected: 401

# Wrong bearer
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:7878/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -H 'Authorization: Bearer wrong-token' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
# Expected: 401

# Missing Accept header
curl -sS -X POST http://127.0.0.1:7878/mcp \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq
# Expected: { "error": { "code":..., "message":"Not Acceptable: Client must accept application/json" } }
```

---

## 6. Cloudflare Tunnel

```bash
# Enable in Settings → Network → Enable Cloudflare Tunnel. Save.
# Within ~3-10 seconds the menu bar shows a *.trycloudflare.com URL.

# In Settings → General, the "Tunnel" row shows the URL with a Copy button.

# Verify it's reachable
TUNNEL=$(curl -sS -H "Authorization: Bearer dev-token-1234" \
  http://127.0.0.1:7878/status | jq -r .tunnel_url)
curl -sS "$TUNNEL/health" | jq

# Disable the tunnel in Settings. The menu bar row + /status both reflect "off".
```

---

## 7. Settings UX

| What to verify | Expected behavior |
|----------------|-------------------|
| Open Settings via menu bar | Window appears, centered, three tabs |
| Open Settings via `Cmd+,` | Same as above |
| Paste into "Endpoint URL" with `Cmd+V` | Pasted content appears in the field |
| Cut, copy, select all in any field | Standard macOS behavior works |
| `Cmd+Z` to undo a typed change | Field reverts |
| Click Save | Green "✓ Saved" appears next to the button, fades after ~1.8s |
| Save again immediately | Indicator stays visible (timer extends) |
| Type `99999` in Local API port | On blur or save, value clamps to range |
| Paste `7,878` in port field | Comma stripped (formatter rejects grouping) |
| Toggle the Cloudflare Tunnel switch | Live tunnel row appears with ProgressView, then URL + Copy |

---

## 8. Permission flows

### First-launch flow

```bash
# Reset FDA so the next launch hits the friendly prompt
tccutil reset SystemPolicyAllFiles com.imsg-relay.app

# Launch
open "/Applications/iMessage Relay.app"
```

Expected:
1. Menu bar icon appears, but no relay is running yet
2. A friendly NSAlert appears: "iMessage Relay needs Full Disk Access" with buttons:
   - **Open Privacy Settings…** — jumps to the right System Settings pane
   - **Try Again** — re-checks FDA on demand
   - **Quit**
3. Click "Open Privacy Settings…", toggle the app on
4. Within ~2 seconds, the menu bar transitions to the normal runtime state. No need to click "Try Again". This is the auto-poll feature working.

### Granted-then-revoked

```bash
# With the app running and FDA on, revoke FDA from System Settings.
# Send yourself a message.
# Expected: relay either keeps running (it has a held file handle) or
# gracefully shows the prompt again when next started. No crash.
```

---

## 9. Crash / restart resilience

```bash
# 1. With a working endpoint + tunnel, send yourself ~10 messages quickly
# 2. Kill the app mid-flow
killall -9 ImsgRelay

# 3. Check queue persisted
sqlite3 "$HOME/Library/Application Support/imsg-relay/relay.sqlite3" \
  "SELECT state, COUNT(*) FROM events GROUP BY state"

# 4. Relaunch
open "/Applications/iMessage Relay.app"
# 5. Queue drains within seconds — no events lost
```

---

## 10. Build / release pipeline (smoke only)

```bash
# Local build chain
make clean
make build        # debug
make release      # release
make app          # signed bundle
ls -la "iMessage Relay.app/Contents/MacOS/ImsgRelay"

# Check code signature
codesign -dv --verbose=4 "iMessage Relay.app" 2>&1 | head -10
spctl --assess --type execute --verbose=4 "iMessage Relay.app"
```

For full CI release pipeline testing, push a `v0.x.y` tag and watch
GitHub Actions. That path requires real Apple Developer ID secrets in
the repo settings.

---

## Reporting issues

When a test fails, include:

```bash
# Recent app logs
log show --predicate 'subsystem == "com.imsg-relay.app"' --info --last 5m > app.log

# Queue state
sqlite3 "$HOME/Library/Application Support/imsg-relay/relay.sqlite3" \
  "SELECT state, COUNT(*) FROM events GROUP BY state; SELECT * FROM events ORDER BY id DESC LIMIT 10"

# Current config (sanitize bearer token before sharing!)
defaults read com.imsg-relay.app

# Build version
"/Applications/iMessage Relay.app/Contents/MacOS/ImsgRelay" --version 2>/dev/null || \
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "/Applications/iMessage Relay.app/Contents/Info.plist"
```
