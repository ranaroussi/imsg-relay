import Foundation

/// User-tunable configuration persisted in `UserDefaults`.
///
/// Kept deliberately small — the relay is meant to be a "dumb edge node"
/// per the PRD. Anything that smells like business policy belongs on the
/// remote server, not here.
struct AppConfig: Codable, Equatable, Sendable {
    /// Stable identifier the remote server uses to route events
    /// (`server.identifier` in the envelope). Example: `sales`, `support`.
    var serverIdentifier: String

    /// Remote endpoint that receives relayed events.
    var serverEndpoint: String

    /// Bearer token used for `Authorization` on outbound relay POSTs
    /// and required on the local HTTP API when set.
    var bearerToken: String

    /// Local API port. Cloudflared tunnels this port.
    var localAPIPort: Int

    /// MCP server port. Exposed via tunnel so remote callers can mount tools.
    var mcpPort: Int

    /// Toggle for the Cloudflare Tunnel. Off by default so first launch is
    /// silent; users enable it explicitly from Settings.
    var tunnelEnabled: Bool

    /// Include reaction (tapback) events in the inbound stream.
    var includeReactions: Bool

    /// Maximum number of in-flight outbound HTTP attempts before a queued
    /// event is parked as `dead` and surfaced in the menu bar.
    var maxRetryAttempts: Int

    static let `default` = AppConfig(
        serverIdentifier: "",
        serverEndpoint: "",
        bearerToken: "",
        localAPIPort: 7878,
        mcpPort: 7879,
        tunnelEnabled: false,
        includeReactions: true,
        maxRetryAttempts: 12
    )
}

/// Thread-safe accessor for `AppConfig`. Uses `UserDefaults` so settings
/// survive across launches and so the Settings window can mutate values
/// independently of the runtime services.
final class AppConfigStore: @unchecked Sendable {
    static let shared = AppConfigStore()

    private let lock = NSLock()
    private let defaults = UserDefaults.standard
    private let key = "imsg-relay.config.v1"
    private var cached: AppConfig

    /// Posted whenever `update(_:)` is called. Observers re-read `current`.
    static let didChangeNotification = Notification.Name("AppConfigStore.didChange")

    private init() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            self.cached = decoded
        } else {
            self.cached = .default
        }
    }

    var current: AppConfig {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    func update(_ transform: (inout AppConfig) -> Void) {
        lock.lock()
        var next = cached
        transform(&next)
        cached = next
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: key)
        }
        lock.unlock()
        NotificationCenter.default.post(name: AppConfigStore.didChangeNotification, object: nil)
    }
}
