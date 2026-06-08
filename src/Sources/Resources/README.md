# Resources

Bundled assets copied into `Contents/Resources/` of the `.app` at build time:

- `cloudflared` — Cloudflare Tunnel binary (downloaded per-arch by CI; falls back to system PATH in dev builds).
- App icons (added in a later iteration).

This README is excluded from the Swift bundle via `Package.swift`.
