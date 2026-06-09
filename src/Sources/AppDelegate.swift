import Cocoa
import SwiftUI
import Sparkle
import MCP
import Contacts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var settingsWindow: NSWindow?

    private var queue: RelayQueue?
    private var tunnel: TunnelManager?
    private var relay: HTTPRelay?
    private var imsg: ImsgClient?
    private var api: LocalAPIServer?
    private var mcp: MCPService?
    private var mcpTransport: StatelessHTTPServerTransport?
    private var mcpTask: Task<Void, Error>?
    private var contacts: ContactsResolver?

    private var updater: SPUStandardUpdaterController?

    /// Snapshot of tunnel-relevant config from the last time we
    /// applied changes. Used by `configChanged` to decide whether to
    /// stop+restart the tunnel after a Save — we only restart when
    /// the user actually touched something tunnel-related, not every
    /// time they tweak an unrelated field.
    private struct TunnelConfigSnapshot: Equatable {
        var enabled: Bool
        var mode: TunnelMode
        var token: String
        var hostname: String
        var port: Int
    }
    private var lastTunnelSnapshot: TunnelConfigSnapshot?

    /// True between the moment we detect missing Full Disk Access and
    /// the moment we successfully boot. The menu bar uses this to swap
    /// in a recovery-focused menu rather than the normal runtime menu.
    private var awaitingPermissions = false

    /// Background poll that quietly re-checks FDA every couple of
    /// seconds after the user has been sent to System Settings. Lets
    /// us auto-resume without the user having to click Try Again.
    private var permissionPollTimer: Timer?

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Foundation.Notification) {
        // Sparkle aborts hard if SUPublicEDKey is missing. Skip the updater
        // entirely until a release build injects a real key.
        let pubKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        if !pubKey.isEmpty {
            updater = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }

        installMainMenu()
        setupMenuBar()
        bootRuntime()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configChanged),
            name: AppConfigStore.didChangeNotification,
            object: nil
        )

        // Surfaced by `TunnelManager` when the user picks named-mode
        // but hasn't entered the token + hostname. The alert in
        // `TunnelManager.showNamedTunnelMisconfiguredAlert()` posts
        // this so we can present the Settings window.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: .imsgOpenSettings,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Foundation.Notification) {
        stopPermissionPolling()
        Task { await relay?.stop() }
        api?.stop()
        tunnel?.stop()
        mcpTask?.cancel()
        if let mcpTransport {
            Task { await mcpTransport.disconnect() }
        }
    }

    // MARK: Runtime

    private func bootRuntime() {
        // Probe Full Disk Access before constructing ImsgClient. The
        // alternative — letting IMsgCore throw `authorization denied`
        // and surfacing that as a fatal alert — is hostile UX. We'd
        // rather show a friendly prompt that links straight to System
        // Settings and offers a Try Again button.
        guard Permissions.hasFullDiskAccess() else {
            awaitingPermissions = true
            refreshMenu()
            presentFullDiskAccessNeeded()
            return
        }
        awaitingPermissions = false
        stopPermissionPolling()

        do {
            let queue = try RelayQueue()
            let tunnel = TunnelManager()
            let relay = HTTPRelay(queue: queue, tunnel: tunnel)
            // Contacts resolver is best-effort: created unconditionally
            // so callers can rely on it being non-nil, but
            // `name(for:)` returns nil until the user grants access.
            // Stored on AppDelegate so the optional UI prompt + the
            // `CNContactStoreDidChange` invalidation can reach it.
            let contacts = ContactsResolver()
            self.contacts = contacts
            let imsg  = try ImsgClient(queue: queue, relay: relay, tunnel: tunnel, contacts: contacts)
            tunnel.attach(relay: relay)

            // We DON'T auto-request Contacts access on boot. This is
            // an `LSUIElement` (menu bar) app — without a regular
            // foreground activation policy, TCC refuses to show the
            // permission dialog and immediately denies the request,
            // permanently caching the deny. Instead, the Settings UI
            // exposes a "Grant Contacts Access" button that calls
            // `NSApp.activate(ignoringOtherApps: true)` before
            // requesting — which makes TCC show the prompt as
            // expected. See `requestContactsAccess()`.

            // Invalidate the resolver's cache when the user edits a
            // contact (e.g. adds a name for a previously-unknown
            // handle) so the next event picks up the change without
            // restarting the app.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(contactStoreChanged),
                name: .CNContactStoreDidChange,
                object: nil
            )

            // HTTP MCP: a `StatelessHTTPServerTransport` from the SDK
            // gets bound to the SDK's `Server`, and the same transport
            // is handed to `LocalAPIServer` which routes `POST /mcp`
            // through it. OriginValidator is disabled because tunnel
            // traffic arrives from arbitrary external clients; the
            // bearer auth middleware on LocalAPIServer is the gate.
            let mcpTransport = StatelessHTTPServerTransport(
                validationPipeline: StandardValidationPipeline(validators: [
                    OriginValidator.disabled,
                    AcceptHeaderValidator(mode: .jsonOnly),
                    ContentTypeValidator(),
                    ProtocolVersionValidator(),
                ])
            )
            let mcp = MCPService(imsg: imsg, transport: mcpTransport)

            let api = LocalAPIServer(
                port: AppConfigStore.shared.current.localAPIPort,
                imsg: imsg,
                tunnel: tunnel,
                queue: queue,
                mcpTransport: mcpTransport
            )

            self.queue = queue
            self.tunnel = tunnel
            self.relay = relay
            self.imsg = imsg
            self.api = api
            self.mcp = mcp
            self.mcpTransport = mcpTransport

            Task { await relay.start() }
            Task { await imsg.startWatching() }
            mcpTask = Task { try await mcp.run() }
            api.start()
            relay.relay(type: .relayStarted, payload: AnyCodable([:] as [String: Any]))

            if AppConfigStore.shared.current.tunnelEnabled {
                startTunnel()
            }
            // Seed the snapshot so subsequent `configChanged` calls
            // compare against what we just booted with, not nil.
            let cfg = AppConfigStore.shared.current
            self.lastTunnelSnapshot = TunnelConfigSnapshot(
                enabled: cfg.tunnelEnabled,
                mode: cfg.tunnelMode,
                token: cfg.tunnelToken,
                hostname: cfg.tunnelHostname,
                port: cfg.localAPIPort
            )
            refreshMenu()
        } catch {
            Log.app.error("Failed to boot runtime: \(error.localizedDescription, privacy: .public)")
            // If a TCC race slipped past our probe (granted-then-revoked,
            // or `chat.db` only became readable mid-init), surface the
            // friendly permission prompt instead of the scary one.
            if !Permissions.hasFullDiskAccess() {
                awaitingPermissions = true
                refreshMenu()
                presentFullDiskAccessNeeded()
            } else {
                presentFatal(error)
            }
        }
    }

    private func startTunnel() {
        let port = AppConfigStore.shared.current.localAPIPort
        tunnel?.start(port: port) { [weak self] url in
            DispatchQueue.main.async { self?.refreshMenu() }
            if let url { Log.tunnel.info("tunnel up: \(url, privacy: .public)") }
        }
    }

    @objc private func configChanged() {
        refreshMenu()
        let cfg = AppConfigStore.shared.current
        let snapshot = TunnelConfigSnapshot(
            enabled: cfg.tunnelEnabled,
            mode: cfg.tunnelMode,
            token: cfg.tunnelToken,
            hostname: cfg.tunnelHostname,
            port: cfg.localAPIPort
        )

        // Restart the tunnel only when something tunnel-relevant
        // changed (enabled toggle, mode pick, token, hostname, or
        // local API port — the last because quick mode binds to that
        // specific port). Unrelated saves (bearer token rotation,
        // backfill toggle, …) don't bounce the tunnel.
        let prev = lastTunnelSnapshot
        let changed = prev != snapshot
        lastTunnelSnapshot = snapshot

        if !changed { return }

        if tunnel?.isRunning == true { tunnel?.stop() }
        if cfg.tunnelEnabled { startTunnel() }
    }

    // MARK: Main menu (keybindings)

    /// Install a minimal `NSApp.mainMenu` so SwiftUI text fields get
    /// `Cmd+C / V / X / A / Z / Shift+Z`. Without this, the responder
    /// chain has no menu item bound to those key equivalents and the
    /// shortcuts no-op silently — a classic `LSUIElement` gotcha for
    /// menu-bar-only apps with a Settings window.
    ///
    /// The menu itself stays invisible (LSUIElement still hides the
    /// app's menu bar from the system bar); it's purely there to wire
    /// the keybindings into the responder chain.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit iMessage Relay",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",       action: Selector(("undo:")),               keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")),           keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut",        action: #selector(NSText.cut(_:)),         keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",       action: #selector(NSText.copy(_:)),        keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",      action: #selector(NSText.paste(_:)),       keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),   keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.menuBarImage()
            button.image?.accessibilityDescription = "iMessage Relay"
        }
        menu = NSMenu()
        statusItem.menu = menu
        refreshMenu()
    }

    /// Load the bundled menu bar glyph and mark it as a template so macOS
    /// inverts it automatically for light/dark menu bars. We grab the @2x
    /// asset explicitly because `NSImage(named:)` against `Bundle.module`
    /// is unreliable for unscaled PNGs — looking up a single file and
    /// stamping the desired point size on it is more predictable.
    private static func menuBarImage() -> NSImage {
        let bundle = Bundle.module
        // `.copy("Resources")` in Package.swift preserves the directory
        // structure inside the resource bundle, so we look under the
        // "Resources" subdirectory rather than the bundle root.
        let candidates = ["MenuBarIcon@2x", "MenuBarIcon@3x", "MenuBarIcon"]
        for name in candidates {
            let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "Resources")
                ?? bundle.url(forResource: name, withExtension: "png")
            if let url, let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                return image
            }
        }
        // Fallback so the menu bar item is at least visible if the bundle
        // copy ever regresses in CI.
        let fallback = NSImage(systemSymbolName: "message.badge.filled.fill",
                               accessibilityDescription: "iMessage Relay") ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }

    private func refreshMenu() {
        menu.removeAllItems()

        if awaitingPermissions {
            menu.addItem(.titled("iMessage Relay — Full Disk Access required"))
            menu.addItem(.separator())
            menu.addItem(.action("Open Privacy Settings…",
                                 target: self,
                                 action: #selector(openPrivacySettings),
                                 key: ""))
            menu.addItem(.action("Try Again",
                                 target: self,
                                 action: #selector(retryBoot),
                                 key: "r"))
            menu.addItem(.separator())
            menu.addItem(.action("Quit iMessage Relay",
                                 target: self,
                                 action: #selector(quit),
                                 key: "q"))
            return
        }

        let cfg = AppConfigStore.shared.current
        let identifier = cfg.serverIdentifier.isEmpty ? "(unconfigured)" : cfg.serverIdentifier
        menu.addItem(.titled("iMessage Relay — \(identifier)"))
        menu.addItem(.separator())

        let tunnelLine: String
        if let url = tunnel?.publicURL, !url.isEmpty {
            tunnelLine = "Tunnel: \(url)"
        } else if cfg.tunnelEnabled {
            tunnelLine = "Tunnel: connecting…"
        } else {
            tunnelLine = "Tunnel: disabled"
        }
        let tunnelItem = NSMenuItem.titled(tunnelLine)
        if tunnel?.publicURL != nil {
            tunnelItem.target = self
            tunnelItem.action = #selector(copyTunnelURL)
            tunnelItem.toolTip = "Click to copy"
        }
        menu.addItem(tunnelItem)

        let stats = queue?.stats() ?? (0, 0)
        menu.addItem(.titled("Queue: \(stats.0) pending, \(stats.1) dead"))

        menu.addItem(.separator())
        menu.addItem(.action("Settings…", target: self, action: #selector(openSettings), key: ","))
        menu.addItem(.action("Restart relay", target: self, action: #selector(restartRelay), key: "r"))
        menu.addItem(.action("Restart tunnel", target: self, action: #selector(restartTunnel), key: "t"))
        if stats.1 > 0 {
            menu.addItem(.action("Clear \(stats.1) dead event\(stats.1 == 1 ? "" : "s")",
                                 target: self,
                                 action: #selector(clearDeadEvents),
                                 key: ""))
        }
        menu.addItem(.separator())
        menu.addItem(.action("Check for updates…", target: self, action: #selector(checkUpdates), key: ""))
        menu.addItem(.action("Quit iMessage Relay", target: self, action: #selector(quit), key: "q"))
    }

    @objc private func copyTunnelURL() {
        guard let url = tunnel?.publicURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
            let win = NSWindow(contentViewController: host)
            win.title = "iMessage Relay Settings"
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.isReleasedWhenClosed = false
            settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func restartRelay() {
        Task {
            await relay?.stop()
            await relay?.start()
        }
    }

    @objc private func restartTunnel() {
        tunnel?.stop()
        if AppConfigStore.shared.current.tunnelEnabled { startTunnel() }
    }

    /// Forwarded from `CNContactStoreDidChange`. The OS fires this
    /// the moment the user edits anything in Contacts — including
    /// adding a name for a previously-unknown handle. Wipe the
    /// resolver's in-memory cache so the next event picks up the
    /// change.
    @objc private func contactStoreChanged() {
        contacts?.invalidate()
        Log.contacts.debug("CNContactStore changed; resolver cache invalidated")
    }

    /// Called from the Settings UI. Foregrounds the app first because
    /// TCC will not present its permission dialog to an `LSUIElement`
    /// process — the request silently fails with "Access Denied" and
    /// the deny is then cached forever. Activating first guarantees
    /// the system shows the prompt to the user.
    func requestContactsAccess() async -> Bool {
        guard let contacts else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let ok = await contacts.requestAccess()
        Log.contacts.info("user-initiated Contacts request: granted=\(ok, privacy: .public)")
        return ok
    }

    /// Snapshot of the current Contacts authorization state for the
    /// Settings UI. Static-by-type because `CNContactStore` reports
    /// the system value, not per-instance.
    nonisolated func contactsAuthorizationStatus() -> CNAuthorizationStatus {
        ContactsResolver.authorizationStatus()
    }

    /// Self-service escape hatch for users who land in a "denied but
    /// not visible in System Settings" state. We shell out to
    /// `/usr/bin/tccutil` which clears TCC's record for our bundle
    /// ID; the next `requestAccess` then prompts fresh and registers
    /// us in the Privacy pane.
    ///
    /// Notes:
    ///   - `tccutil reset <SERVICE> <BUNDLE_ID>` does NOT require
    ///     sudo for apps the user owns. It can no-op (exit status
    ///     != 0) if there's no existing TCC entry to reset — that's
    ///     fine and we log-but-ignore.
    ///   - We `waitUntilExit()` synchronously so the caller can
    ///     immediately follow up with `requestAccess()` against the
    ///     freshly-cleared state.
    ///   - `nonisolated` because the subprocess spawn touches no
    ///     AppDelegate state and we want to call it from a detached
    ///     Task to avoid blocking the main actor during waitUntilExit.
    nonisolated func resetContactsPermissions() {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            Log.contacts.error("resetContactsPermissions: missing bundle identifier")
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Contacts", bundleID]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            Log.contacts.info("tccutil reset Contacts \(bundleID, privacy: .public) → exit \(task.terminationStatus, privacy: .public)")
        } catch {
            Log.contacts.error("tccutil reset failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func clearDeadEvents() {
        let cleared = queue?.clearDead() ?? 0
        Log.app.info("user cleared \(cleared, privacy: .public) dead events")
        refreshMenu()
    }

    @objc private func checkUpdates() {
        updater?.checkForUpdates(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openPrivacySettings() {
        Permissions.openFullDiskAccessSettings()
    }

    @objc private func retryBoot() {
        bootRuntime()
    }

    /// Friendly, non-scary, retry-able prompt shown when Full Disk
    /// Access hasn't been granted yet. We deliberately avoid
    /// `alertStyle = .critical` and the giant red triangle — it's a
    /// first-launch permission request, not an emergency.
    private func presentFullDiskAccessNeeded() {
        let alert = NSAlert()
        alert.messageText = "Grant Full Disk Access to iMessage Relay"
        alert.informativeText = """
        iMessage Relay reads your Messages history from \
        ~/Library/Messages/chat.db, which macOS protects behind \
        Full Disk Access.

        1. Click "Open Privacy Settings".
        2. Toggle iMessage Relay on in the list (drag the app in if \
        it's not there yet).
        3. Come back and click "Try Again".
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Quit")

        // Bring the app forward so the user actually sees the alert
        // rather than discovering it later behind other windows.
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Permissions.openFullDiskAccessSettings()
            // Don't badger the user with the alert again — they're
            // about to be busy in System Settings. Start a quiet
            // background poll instead; the moment macOS flips FDA on,
            // we'll auto-boot. If the user dismisses everything, the
            // menu bar still exposes a "Try Again" recovery path.
            startPermissionPolling()
        case .alertSecondButtonReturn:
            bootRuntime()
        default: // Quit
            NSApp.terminate(nil)
        }
    }

    /// Poll `Permissions.hasFullDiskAccess()` on the main runloop until
    /// it returns `true`, then boot the runtime. Cheap: opens a file
    /// handle every couple of seconds. Stops itself once boot succeeds.
    private func startPermissionPolling() {
        stopPermissionPolling()
        // Timer fires on the runloop thread it was scheduled on (main,
        // here), but Swift 6 wants an explicit hop to the MainActor
        // before we touch `self`. We discard the timer block argument
        // because piping it across the actor hop trips
        // SendingRisksDataRace — we invalidate through the property
        // instead, which has the same effect and is actor-safe.
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if Permissions.hasFullDiskAccess() {
                    self.stopPermissionPolling()
                    self.bootRuntime()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    private func presentFatal(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "iMessage Relay failed to start"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }
}

// MARK: - NSMenuItem ergonomics

private extension NSMenuItem {
    static func titled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    static func action(_ title: String, target: AnyObject, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
}

extension Foundation.Notification.Name {
    /// Posted by helper code that wants the Settings window opened
    /// (e.g. the named-tunnel misconfigured alert). `AppDelegate`
    /// listens and calls its `openSettings` action.
    static let imsgOpenSettings = Foundation.Notification.Name("ImsgRelay.openSettings")
}
