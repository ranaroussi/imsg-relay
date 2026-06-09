import SwiftUI
import AppKit
import Contacts
import ServiceManagement

struct SettingsView: View {
    @State private var config: AppConfig = AppConfigStore.shared.current
    @ObservedObject private var tunnel = TunnelStatus.shared
    @State private var copied = false
    @State private var justSaved = false
    @State private var contactsStatus: CNAuthorizationStatus = ContactsResolver.authorizationStatus()
    @State private var contactsRequestInFlight = false
    @State private var showAdvancedPorts = false
    @State private var launchOnLogin: Bool = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                outboundTab.tabItem { Label("Outbound", systemImage: "arrow.up.right.circle") }
                inboundTab.tabItem  { Label("Inbound",  systemImage: "arrow.down.left.circle") }
                generalTab.tabItem  { Label("General",  systemImage: "gear") }
            }
            .padding(12)

            Divider()
            saveBar
        }
        .frame(width: 640, height: 600)
        .onReceive(NotificationCenter.default.publisher(for: AppConfigStore.didChangeNotification)) { _ in
            config = AppConfigStore.shared.current
        }
    }

    // MARK: - Outbound

    private var outboundTab: some View {
        tabScroll {
            section("Relay identity") {
                row("Identifier",
                    help: "Sent as server.identifier on every event.") {
                    TextField("e.g. sales, support, personal", text: $config.serverIdentifier)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
                rowDivider
                row("Webhook URL",
                    help: "Auth via the bearer token configured on the Inbound tab.") {
                    TextField("https://your-server.example.com/imessage", text: $config.serverEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
            }

            section("Stream") {
                row("Include reactions (tapbacks)") {
                    Toggle("", isOn: $config.includeReactions)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                rowDivider
                row("Backfill missed messages on restart",
                    help: "Off by default so a long quit period doesn't dump multi-day history to your endpoint at once.") {
                    Toggle("", isOn: $config.backfillOnRestart)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            section("Reliability") {
                row("Max retry attempts",
                    help: "After this many failed POSTs the event is parked as 'dead' (visible in the menu bar). Backoff is exponential: min(60s, 2^attempts).") {
                    stepperField(value: $config.maxRetryAttempts, range: 1...64, width: 70)
                }
            }
        }
    }

    // MARK: - Inbound

    private var inboundTab: some View {
        tabScroll {
            section("Auth") {
                row("Bearer token",
                    help: "Required on incoming local API + MCP HTTP calls when set, and also sent on outbound webhook POSTs. One secret, two directions.") {
                    SecureField("", text: $config.bearerToken)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
            }

            section("Cloudflare Tunnel") {
                row("Enable tunnel",
                    help: "Exposes the local API + MCP via Cloudflare's edge so your remote server can reach this Mac.") {
                    Toggle("", isOn: $config.tunnelEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if config.tunnelEnabled {
                    rowDivider
                    row("Mode") {
                        Picker("", selection: $config.tunnelMode) {
                            Text("Free").tag(TunnelMode.quick)
                            Text("Named (custom)").tag(TunnelMode.named)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 280)
                    }

                    switch config.tunnelMode {
                    case .quick:
                        rowDivider
                        quickModeStatus
                    case .named:
                        rowDivider
                        namedTunnelPreflight
                        rowDivider
                        row("Tunnel token") {
                            SecureField("", text: $config.tunnelToken)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 280)
                        }
                        rowDivider
                        row("Public hostname") {
                            TextField("", text: $config.tunnelHostname)
                                .textFieldStyle(.roundedBorder)
                                .disableAutocorrection(true)
                                .frame(maxWidth: 280)
                        }

                        if config.tunnelToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || config.tunnelHostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            rowDivider
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("Both token and hostname are required to start a named tunnel.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                    }
                }
            }

            DisclosureGroup(isExpanded: $showAdvancedPorts) {
                sectionCard {
                    row("Local API port",
                        help: "HTTP port the local API binds to. Cloudflared tunnels this port.") {
                        stepperField(value: $config.localAPIPort, range: 1024...65535, width: 90)
                    }
                    rowDivider
                    row("MCP port",
                        help: "Port the MCP HTTP transport binds to.") {
                        stepperField(value: $config.mcpPort, range: 1024...65535, width: 90)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Advanced — local ports")
                    .font(.callout.weight(.semibold))
            }
        }
    }

    // MARK: - General

    private var generalTab: some View {
        tabScroll {
            section("Contacts") {
                contactsRow
            }

            section("Startup") {
                row("Launch on login",
                    help: "Adds iMessage Relay to your macOS login items so it starts automatically when you log in.") {
                    Toggle("", isOn: $launchOnLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: launchOnLogin) { _, newValue in
                            updateLaunchOnLogin(newValue)
                        }
                }
            }

            section("Permissions") {
                permissionRow("Full Disk Access",
                              detail: "Required to read ~/Library/Messages/chat.db.")
                rowDivider
                permissionRow("Automation → Messages",
                              detail: "Required to send messages via Messages.app. Prompted on first send.")
            }

            section("About") {
                row("Version") {
                    Text(Self.shortVersion()).foregroundStyle(.secondary)
                }
                rowDivider
                row("Build") {
                    Text(Self.buildNumber()).foregroundStyle(.secondary)
                }
                rowDivider
                row("Bundle") {
                    Text(Bundle.main.bundleIdentifier ?? "—")
                        .foregroundStyle(.secondary)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - Contacts row (sub-component because of multi-state buttons)

    @ViewBuilder
    private var contactsRow: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(contactsStatusLabel)
                    Text(contactsStatusHelp).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch contactsStatus {
                case .notDetermined:
                    Button(action: requestContactsAccess) {
                        if contactsRequestInFlight {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Grant Access")
                        }
                    }
                    .disabled(contactsRequestInFlight)
                case .denied, .restricted:
                    HStack(spacing: 8) {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button(action: resetAndRerequestContactsAccess) {
                            if contactsRequestInFlight {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Reset & Re-request")
                            }
                        }
                        .disabled(contactsRequestInFlight)
                        .help("Clears the macOS permission record for this app and immediately re-asks.")
                    }
                case .authorized, .limited:
                    Text("Granted").foregroundStyle(.green)
                @unknown default:
                    EmptyView()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            contactsStatus = ContactsResolver.authorizationStatus()
        }
    }

    private var contactsStatusLabel: String {
        switch contactsStatus {
        case .notDetermined: return "Resolve handles to contact names"
        case .denied, .restricted: return "Contacts access denied"
        case .authorized, .limited: return "Contacts access granted"
        @unknown default: return "Contacts access (unknown state)"
        }
    }

    private var contactsStatusHelp: String {
        switch contactsStatus {
        case .notDetermined:
            return "When granted, inbound events carry a sender_name field resolved from your Contacts."
        case .denied, .restricted:
            return "Inbound events carry the raw phone/email handle. If the app isn't listed in System Settings, use 'Reset & Re-request'."
        case .authorized, .limited:
            return "Inbound events carry sender_name resolved from your Contacts."
        @unknown default:
            return ""
        }
    }

    private func requestContactsAccess() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        contactsRequestInFlight = true
        Task {
            _ = await delegate.requestContactsAccess()
            await MainActor.run {
                contactsStatus = ContactsResolver.authorizationStatus()
                contactsRequestInFlight = false
            }
        }
    }

    private func resetAndRerequestContactsAccess() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        contactsRequestInFlight = true
        Task {
            await Task.detached { delegate.resetContactsPermissions() }.value
            try? await Task.sleep(nanoseconds: 250_000_000)
            _ = await delegate.requestContactsAccess()
            await MainActor.run {
                contactsStatus = ContactsResolver.authorizationStatus()
                contactsRequestInFlight = false
            }
        }
    }

    /// Toggles macOS login items via SMAppService.mainApp. On error
    /// we revert the @State so the UI doesn't lie about reality —
    /// e.g. a sandbox or permission failure that left the system in
    /// the prior state.
    private func updateLaunchOnLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.app.info("Launch on login: \(enable, privacy: .public)")
        } catch {
            Log.app.error("Launch on login \(enable ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            // Revert the toggle to match the actual system state.
            launchOnLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Permission row (info-only)

    private func permissionRow(_ title: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Tunnel status (quick mode only — named hostname is identical to user input so we hide it)

    @ViewBuilder
    private var quickModeStatus: some View {
        if let url = tunnel.publicURL {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Public URL")
                    Text(url)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(tunnel.isRunning ? "Connecting to trycloudflare.com…" : "Starting cloudflared…")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Named-tunnel pre-flight checklist

    @ViewBuilder
    private var namedTunnelPreflight: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Complete these in the Cloudflare dashboard first:",
                  systemImage: "info.circle")
                .font(.caption.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("1. **Zero Trust → Networks → Tunnels → Create a tunnel**")
                Text("2. Copy the connector token (`eyJh…`)")
                Text("3. **Public Hostnames → Add a public hostname**")
                Text("    • Subdomain + your domain")
                Text("    • Service: HTTP, URL: `localhost:\(String(config.localAPIPort))`")
                Text("    *← this step creates the DNS record. Skipping it means the tunnel connects but no traffic reaches your Mac.*")
                    .foregroundStyle(.orange)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 22)

            HStack(spacing: 12) {
                Link("Open Cloudflare dashboard",
                     destination: URL(string: "https://one.dash.cloudflare.com/")!)
                    .font(.caption)
                Link("Full walkthrough (README)",
                     destination: URL(string: "https://github.com/ranaroussi/imsg-relay/blob/main/README.md#setting-up-a-named-tunnel")!)
                    .font(.caption)
            }
            .padding(.leading, 22)
        }
        .padding(10)
    }

    // MARK: - Save bar (window footer)

    @ViewBuilder
    private var saveBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("© Ran Aroussi")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("GitHub",
                     destination: URL(string: "https://github.com/ranaroussi/imsg-relay")!)
                    .font(.caption)
            }
            Spacer()
            if justSaved {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
        }
        .animation(.easeInOut(duration: 0.18), value: justSaved)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func save() {
        AppConfigStore.shared.update { $0 = config }
        justSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            justSaved = false
        }
    }

    // MARK: - Layout building blocks
    //
    // We dropped Form { .grouped } for these custom blocks because the
    // grouped style ships with non-overridable left padding on Section
    // headers and inset cosmetic margins that fought the design brief
    // ("flush-left titles, no group padding, save as window footer").
    // The result is the same visual vocabulary (rounded cards on a
    // grouped background) but with full control over alignment and
    // spacing.

    /// Outer wrapper for a tab's content. Hosts the ScrollView and
    /// applies the tight outer padding the design calls for.
    @ViewBuilder
    private func tabScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
    }

    /// Section: flush-left title above a rounded card containing the
    /// rows. Collapsible variants are inlined at call sites with
    /// `DisclosureGroup` + `sectionCard` to keep this helper non-
    /// escaping.
    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
            sectionCard(content)
        }
    }

    @ViewBuilder
    private func sectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 0.5)
        )
    }

    /// Standard label-on-left, control-on-right row. Always vertically
    /// centered, regardless of whether the trailing control is a
    /// Toggle (small) or a TextField (medium) or a Picker (large).
    @ViewBuilder
    private func row<Trailing: View>(
        _ label: String,
        help: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Hairline between rows inside a section card.
    @ViewBuilder
    private var rowDivider: some View {
        Divider().padding(.leading, 12)
    }

    /// Text-field + stepper combo. `.grouping(.never)` keeps port
    /// numbers as "7878", not "7,878". Clamps typed values so users
    /// can't escape the valid range by paste.
    @ViewBuilder
    private func stepperField(value: Binding<Int>, range: ClosedRange<Int>, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            TextField("", value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: width)
                .onChange(of: value.wrappedValue) { _, newValue in
                    if newValue < range.lowerBound {
                        value.wrappedValue = range.lowerBound
                    } else if newValue > range.upperBound {
                        value.wrappedValue = range.upperBound
                    }
                }
            Stepper("", value: value, in: range).labelsHidden()
        }
    }

    // MARK: - Version helpers

    private static func shortVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private static func buildNumber() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}
