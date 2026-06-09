import SwiftUI
import AppKit

struct SettingsView: View {
    @State private var config: AppConfig = AppConfigStore.shared.current
    @ObservedObject private var tunnel = TunnelStatus.shared
    @State private var copied = false
    @State private var justSaved = false

    var body: some View {
        TabView {
            generalTab.tabItem  { Label("General",  systemImage: "gear") }
            networkTab.tabItem  { Label("Network",  systemImage: "network") }
            statusTab.tabItem   { Label("Status",   systemImage: "info.circle") }
        }
        // Outer window margin so the tab control floats inside the
        // window chrome instead of running edge-to-edge. Native macOS
        // preferences panes do the same.
        .padding(20)
        .frame(width: 620, height: 540)
        .onReceive(NotificationCenter.default.publisher(for: AppConfigStore.didChangeNotification)) { _ in
            config = AppConfigStore.shared.current
        }
    }

    // MARK: - General

    private var generalTab: some View {
        formScreen {
            Section("Relay identity") {
                LabeledContent("Identifier") {
                    TextField("", text: $config.serverIdentifier, prompt: Text("e.g. sales, support, personal"))
                        .textFieldStyle(.roundedBorder)
                }
                .help("Sent as server.identifier on every event.")

                LabeledContent("Endpoint URL") {
                    TextField("", text: $config.serverEndpoint, prompt: Text("https://your-server.example.com/imessage"))
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent("Bearer token") {
                    SecureField("", text: $config.bearerToken, prompt: Text("Leave blank to disable auth (dev only)"))
                        .textFieldStyle(.roundedBorder)
                }
                .help("Sent as Authorization: Bearer <token>.")
            }

            Section("Inbound stream") {
                Toggle("Include reactions (tapbacks)", isOn: $config.includeReactions)

                Toggle("Backfill missed messages on restart",
                       isOn: $config.backfillOnRestart)
                    .help("When on, messages received while iMessage Relay was offline get relayed once it restarts. Off by default so a long quit period doesn't dump multi-day history to your endpoint at once.")
            }
        }
    }

    // MARK: - Network

    private var networkTab: some View {
        formScreen {
            Section("Ports") {
                numberRow("Local API port",
                          value: $config.localAPIPort,
                          range: 1024...65535,
                          width: 90)
                numberRow("MCP port",
                          value: $config.mcpPort,
                          range: 1024...65535,
                          width: 90)
            }

            Section("Cloudflare Tunnel") {
                Toggle("Enable tunnel", isOn: $config.tunnelEnabled)
                    .help("Exposes the local API + MCP via a public trycloudflare.com URL.")

                if config.tunnelEnabled {
                    tunnelStatusRow
                }
            }

            Section("Reliability") {
                numberRow("Max retry attempts",
                          value: $config.maxRetryAttempts,
                          range: 1...64,
                          width: 60)
            }
        }
    }

    /// Real text-field + stepper combo, the canonical macOS pattern.
    /// `.grouping(.never)` keeps port numbers as "7878", not "7,878".
    /// `labelsHidden()` on the stepper drops its auto-generated label
    /// so we don't double up with the `LabeledContent` label.
    @ViewBuilder
    private func numberRow(_ label: String,
                           value: Binding<Int>,
                           range: ClosedRange<Int>,
                           width: CGFloat) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                TextField("", value: value, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: width)
                    .onChange(of: value.wrappedValue) { _, newValue in
                        // Clamp typed values so users can't escape the
                        // valid range by pasting or typing freely.
                        if newValue < range.lowerBound {
                            value.wrappedValue = range.lowerBound
                        } else if newValue > range.upperBound {
                            value.wrappedValue = range.upperBound
                        }
                    }
                Stepper("", value: value, in: range)
                    .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private var tunnelStatusRow: some View {
        if let url = tunnel.publicURL {
            VStack(alignment: .leading, spacing: 6) {
                Text("Public URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(url)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

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
            }
            .padding(.vertical, 2)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(tunnel.isRunning ? "Connecting to trycloudflare.com…" : "Starting cloudflared…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Status

    private var statusTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Permissions") {
                    VStack(alignment: .leading, spacing: 10) {
                        permissionRow(
                            "Full Disk Access",
                            detail: "Required to read ~/Library/Messages/chat.db."
                        )
                        permissionRow(
                            "Automation → Messages",
                            detail: "Required to send messages via Messages.app. Prompted on first send."
                        )
                        permissionRow(
                            "Contacts",
                            detail: "Optional. Resolves phone numbers / emails to contact names on inbound events."
                        )
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("About") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Version", value: Self.shortVersion())
                        LabeledContent("Build",   value: Self.buildNumber())
                        LabeledContent("Bundle",  value: Bundle.main.bundleIdentifier ?? "—")
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("Permission prompts come from macOS, not from iMessage Relay. The app will sit idle until they are granted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(20)
        }
    }

    private func permissionRow(_ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Layout helpers

    /// Wraps a settings page in a grouped Form + a sticky save bar at
    /// the bottom. The grouped Form already has its own internal
    /// padding from macOS — we don't add any more, so sections stay
    /// compact. Outer window margin is applied at the TabView level.
    @ViewBuilder
    private func formScreen<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Form {
                content()
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 10) {
                if justSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .animation(.easeInOut(duration: 0.18), value: justSaved)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private func save() {
        AppConfigStore.shared.update { $0 = config }
        justSaved = true
        // Fade the indicator back out after a beat. We don't cancel
        // an in-flight reset because back-to-back Saves just extend
        // the visible window, which is the intuitive behavior.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            justSaved = false
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
