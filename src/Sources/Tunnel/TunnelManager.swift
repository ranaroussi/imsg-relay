import Foundation
import AppKit

/// Supervises a `cloudflared` child process and exposes the public URL.
/// Emits `tunnel.*` events on the relay so the remote server always
/// knows the current callback URL.
///
/// Two modes (see `TunnelMode`):
///   - `.quick`: `cloudflared tunnel --url http://localhost:<port>`,
///     URL parsed from stderr (`*.trycloudflare.com`).
///   - `.named`: `cloudflared tunnel run --token <token>`, URL fixed
///     by `config.tunnelHostname`. Stderr only used to detect the
///     "tunnel connection registered" signal that means traffic can
///     start flowing.
///
/// Lookup order for the binary:
///   1. Bundled inside `Contents/Resources/cloudflared` (CI release builds)
///   2. `/opt/homebrew/bin/cloudflared` (Apple Silicon Homebrew)
///   3. `/usr/local/bin/cloudflared` (Intel Homebrew)
///   4. `which cloudflared` (PATH)
final class TunnelManager: @unchecked Sendable {
    private var process: Process?
    private(set) var isRunning = false
    private(set) var publicURL: String?
    private let urlLock = NSLock()
    private weak var relay: HTTPRelay?

    /// Per-mode runtime: how to invoke `cloudflared` and how to
    /// recognize "the tunnel is live" from its stderr.
    private struct Runtime: Sendable {
        let arguments: [String]
        /// Maps a stderr chunk → the public URL the tunnel will be
        /// reachable at, or `nil` if this chunk doesn't yet signal
        /// readiness. Called repeatedly until it returns non-nil.
        let urlExtractor: @Sendable (String) -> String?
    }

    func attach(relay: HTTPRelay) { self.relay = relay }

    /// One-shot URL resolution box. The cloudflared subprocess prints its
    /// URL on stdout/stderr from background threads, and Swift's strict
    /// concurrency model objects to closures that capture mutable state.
    /// Hoisting `resolved` + `completion` into a heap-allocated, locked
    /// box keeps the readability handlers honest and `@Sendable`.
    private final class Resolver: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let callback: @Sendable (String?) -> Void
        init(callback: @escaping @Sendable (String?) -> Void) { self.callback = callback }
        func fire(_ url: String?) {
            lock.lock()
            let firstTime = !done
            done = true
            lock.unlock()
            if firstTime { callback(url) }
        }
    }

    /// Starts the tunnel pointing at `port`. The completion fires with the
    /// public URL once cloudflared prints it (typically <5s) or `nil` on
    /// timeout/failure.
    func start(port: Int, completion: @escaping @Sendable (String?) -> Void) {
        let mode = AppConfigStore.shared.current.tunnelMode
        Log.tunnel.info("start() requested (port=\(port), mode=\(mode.rawValue, privacy: .public))")

        guard !isRunning else {
            Log.tunnel.notice("start() short-circuited: tunnel already running (publicURL=\(self.publicURL ?? "nil", privacy: .public))")
            completion(publicURL)
            return
        }
        guard let execPath = locateCloudflared() else {
            Log.tunnel.error("start() failed: cloudflared binary not found in bundle or on PATH")
            DispatchQueue.main.async { self.showInstallInstructions() }
            completion(nil)
            return
        }
        Log.tunnel.info("using cloudflared at \(execPath, privacy: .public)")

        guard let runtime = buildRuntime(port: port) else {
            // buildRuntime already logged the specific reason
            // (named-mode misconfig). Return silently here.
            completion(nil)
            return
        }

        // Log the argv (redact the token if present so it doesn't
        // hit the system log).
        let safeArgs = runtime.arguments.enumerated().map { idx, arg -> String in
            if idx > 0, runtime.arguments[idx - 1] == "--token" {
                return "<redacted-token-\(arg.count)-chars>"
            }
            return arg
        }
        Log.tunnel.info("spawning cloudflared: \(safeArgs.joined(separator: " "), privacy: .public)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = runtime.arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let resolver = Resolver(callback: completion)
        let consume: @Sendable (FileHandle) -> Void = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

            // Surface the raw stderr too — at debug level only so we
            // don't spam the log in steady state, but available when
            // diagnosing connection failures.
            for line in text.split(separator: "\n") where !line.isEmpty {
                Log.tunnel.debug("cloudflared: \(line, privacy: .public)")
            }

            guard let url = runtime.urlExtractor(text) else { return }
            guard let self else { return }
            self.urlLock.lock()
            let firstTime = self.publicURL != url
            self.publicURL = url
            self.urlLock.unlock()
            guard firstTime else { return }
            Log.tunnel.info("cloudflared URL ready: \(url, privacy: .public)")
            resolver.fire(url)
            self.relay?.relay(
                type: .tunnelChanged,
                payload: AnyCodable(["callback_url": url])
            )
            // Mirror to the SwiftUI-observable singleton so the Settings
            // window can show "Connecting…" → live URL without polling.
            Task { @MainActor in
                TunnelStatus.shared.publicURL = url
                TunnelStatus.shared.isRunning = true
            }
        }

        stdout.fileHandleForReading.readabilityHandler = consume
        stderr.fileHandleForReading.readabilityHandler = consume

        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            Log.tunnel.notice("cloudflared exited (status=\(status), reason=\(reason.rawValue))")
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.publicURL = nil
                self?.relay?.relay(type: .tunnelDisconnected, payload: AnyCodable([:] as [String: Any]))
            }
            Task { @MainActor in
                TunnelStatus.shared.publicURL = nil
                TunnelStatus.shared.isRunning = false
            }
        }

        do {
            try process.run()
            self.process = process
            isRunning = true
            Log.tunnel.info("cloudflared spawned, PID \(process.processIdentifier)")
            relay?.relay(type: .tunnelConnected, payload: AnyCodable([:] as [String: Any]))
            Task { @MainActor in TunnelStatus.shared.isRunning = true }

            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                resolver.fire(nil)
            }
        } catch {
            Log.tunnel.error("failed to launch cloudflared: \(error.localizedDescription, privacy: .public)")
            completion(nil)
        }
    }

    /// Stop the supervised cloudflared. Sends SIGTERM, gives it up to
    /// 3 seconds to exit cleanly, then escalates to SIGKILL.
    /// Returning synchronously from `stop()` matters because the
    /// `configChanged` smart-restart immediately calls `start()` next
    /// and a stale child would make the new one register against the
    /// wrong tunnel — or fail to register at all if a port is bound.
    func stop() {
        guard isRunning, let process else { return }
        let pid = process.processIdentifier
        Log.tunnel.info("stop() sending SIGTERM to cloudflared PID \(pid)")
        process.terminate()

        // Wait briefly for graceful shutdown.
        let deadline = Date().addingTimeInterval(3.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            Log.tunnel.notice("cloudflared PID \(pid) didn't exit on SIGTERM, escalating to SIGKILL")
            kill(pid, SIGKILL)
            // Brief wait for the kernel to reap.
            let killDeadline = Date().addingTimeInterval(1.0)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        self.process = nil
        isRunning = false
        publicURL = nil
        Task { @MainActor in
            TunnelStatus.shared.publicURL = nil
            TunnelStatus.shared.isRunning = false
        }
    }

    /// Compose the per-mode `cloudflared` runtime. Returns `nil` when
    /// the user picked `.named` but hasn't yet entered a token + hostname.
    private func buildRuntime(port: Int) -> Runtime? {
        let cfg = AppConfigStore.shared.current
        switch cfg.tunnelMode {
        case .quick:
            // The historical default. We match `https://<adjective-adjective-noun-noun>.trycloudflare.com`
            // out of stderr — cloudflared prints it ~once, typically
            // within 3 seconds of startup.
            let pattern = "https://[a-z0-9-]+\\.trycloudflare\\.com"
            return Runtime(
                arguments: ["tunnel", "--no-autoupdate", "--url", "http://localhost:\(port)"],
                urlExtractor: { text in
                    guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
                    return String(text[range])
                }
            )

        case .named:
            let token = cfg.tunnelToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = Self.normalizeHostname(cfg.tunnelHostname)
            guard !token.isEmpty, !host.isEmpty else {
                Log.tunnel.error("named tunnel selected but token or hostname is empty")
                DispatchQueue.main.async { self.showNamedTunnelMisconfiguredAlert() }
                return nil
            }
            let publicURL = "https://\(host)"
            // cloudflared in token mode reads the ingress rules from
            // the Cloudflare side, so there's nothing we can verify
            // about local-port mapping from here. We detect "tunnel
            // up" via the `Registered tunnel connection` log line
            // cloudflared prints once each of its four edge
            // connections is healthy. First match flips us into
            // "ready" and surfaces the configured hostname as the
            // public URL.
            //
            // Argument order matters: `--no-autoupdate` is a `tunnel`
            // subcommand flag, not a `run` subcommand flag. Place it
            // BEFORE `run` or cloudflared rejects it with
            // "flag provided but not defined", prints help, and
            // exits 0 within ~40ms — the symptom that hid the named-
            // mode failure prior to this fix.
            return Runtime(
                arguments: ["tunnel", "--no-autoupdate", "run", "--token", token],
                urlExtractor: { text in
                    text.contains("Registered tunnel connection") ? publicURL : nil
                }
            )
        }
    }

    /// Strip an optional `https://` or `http://` prefix and any trailing
    /// slashes so we always compose `https://<bare-hostname>` regardless
    /// of how the user pasted it.
    static func normalizeHostname(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = host.range(of: "^https?://", options: .regularExpression) {
            host.removeSubrange(scheme)
        }
        while host.hasSuffix("/") { host.removeLast() }
        return host
    }

    @MainActor
    private func showNamedTunnelMisconfiguredAlert() {
        let alert = NSAlert()
        alert.messageText = "Cloudflare named tunnel not configured"
        alert.informativeText = """
        You selected "Named tunnel (custom domain)" in Settings but \
        haven't entered both the connector token and the public hostname.

        Open Settings → Network → Cloudflare Tunnel and fill in:
          • Tunnel token (eyJh… from the Zero Trust dashboard)
          • Public hostname (e.g. mcp.yourcompany.com)

        Or switch back to the free `*.trycloudflare.com` tunnel.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NotificationCenter.default.post(name: .imsgOpenSettings, object: nil)
        }
    }

    private func locateCloudflared() -> String? {
        if let bundled = Bundle.main.url(forResource: "cloudflared", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        let candidates = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared", "/usr/bin/cloudflared"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // /usr/bin/which fallback
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["cloudflared"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            return nil
        }
        return nil
    }

    @MainActor
    private func showInstallInstructions() {
        let alert = NSAlert()
        alert.messageText = "cloudflared not installed"
        alert.informativeText = """
        iMessage Relay needs cloudflared to expose your relay to the internet.

        Install with Homebrew:
            brew install cloudflared

        Or download from:
            https://github.com/cloudflare/cloudflared/releases
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copy install command")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("brew install cloudflared", forType: .string)
        }
    }
}
