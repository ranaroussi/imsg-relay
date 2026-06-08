import Foundation
import AppKit

/// Supervises a `cloudflared tunnel --url http://localhost:<port>` child
/// process and exposes the public URL. Emits `tunnel.*` events on the
/// relay so the remote server always knows the current callback URL.
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
        guard !isRunning else {
            completion(publicURL)
            return
        }
        guard let execPath = locateCloudflared() else {
            DispatchQueue.main.async { self.showInstallInstructions() }
            completion(nil)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = ["tunnel", "--no-autoupdate", "--url", "http://localhost:\(port)"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let resolver = Resolver(callback: completion)
        let pattern = "https://[a-z0-9-]+\\.trycloudflare\\.com"
        let consume: @Sendable (FileHandle) -> Void = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            guard let range = text.range(of: pattern, options: .regularExpression) else { return }
            let url = String(text[range])
            guard let self else { return }
            self.urlLock.lock()
            let firstTime = self.publicURL != url
            self.publicURL = url
            self.urlLock.unlock()
            guard firstTime else { return }
            Log.tunnel.info("cloudflared URL: \(url, privacy: .public)")
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

        process.terminationHandler = { [weak self] _ in
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

    func stop() {
        guard isRunning else { return }
        process?.terminate()
        process = nil
        isRunning = false
        publicURL = nil
        Task { @MainActor in
            TunnelStatus.shared.publicURL = nil
            TunnelStatus.shared.isRunning = false
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
