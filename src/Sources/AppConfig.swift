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

    /// When `true`, the watcher resumes from the stored cursor on every
    /// launch, so messages received while the app was offline get
    /// relayed once it comes back up.
    ///
    /// When `false` (default), the cursor is re-primed to the current
    /// `MAX(ROWID)` of `chat.db` at every launch, so only messages that
    /// arrive **after** boot are relayed. This avoids the surprise of
    /// suddenly replaying multi-day history to your endpoint after a
    /// long quit period.
    var backfillOnRestart: Bool

    static let `default` = AppConfig(
        serverIdentifier: "",
        serverEndpoint: "",
        bearerToken: "",
        localAPIPort: 7878,
        mcpPort: 7879,
        tunnelEnabled: false,
        includeReactions: true,
        maxRetryAttempts: 12,
        backfillOnRestart: false
    )

    // Custom decoder so we can extend `AppConfig` with new fields
    // without invalidating already-persisted configs. Missing keys
    // fall back to the `.default` value's field rather than throwing,
    // which is what users want — adding a new toggle shouldn't reset
    // their endpoint / token / etc.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig.default
        self.serverIdentifier  = (try? c.decode(String.self, forKey: .serverIdentifier))  ?? d.serverIdentifier
        self.serverEndpoint    = (try? c.decode(String.self, forKey: .serverEndpoint))    ?? d.serverEndpoint
        self.bearerToken       = (try? c.decode(String.self, forKey: .bearerToken))       ?? d.bearerToken
        self.localAPIPort      = (try? c.decode(Int.self,    forKey: .localAPIPort))      ?? d.localAPIPort
        self.mcpPort           = (try? c.decode(Int.self,    forKey: .mcpPort))           ?? d.mcpPort
        self.tunnelEnabled     = (try? c.decode(Bool.self,   forKey: .tunnelEnabled))     ?? d.tunnelEnabled
        self.includeReactions  = (try? c.decode(Bool.self,   forKey: .includeReactions))  ?? d.includeReactions
        self.maxRetryAttempts  = (try? c.decode(Int.self,    forKey: .maxRetryAttempts))  ?? d.maxRetryAttempts
        self.backfillOnRestart = (try? c.decode(Bool.self,   forKey: .backfillOnRestart)) ?? d.backfillOnRestart
    }

    // Memberwise init for `.default` and direct construction sites.
    init(
        serverIdentifier: String,
        serverEndpoint: String,
        bearerToken: String,
        localAPIPort: Int,
        mcpPort: Int,
        tunnelEnabled: Bool,
        includeReactions: Bool,
        maxRetryAttempts: Int,
        backfillOnRestart: Bool
    ) {
        self.serverIdentifier = serverIdentifier
        self.serverEndpoint = serverEndpoint
        self.bearerToken = bearerToken
        self.localAPIPort = localAPIPort
        self.mcpPort = mcpPort
        self.tunnelEnabled = tunnelEnabled
        self.includeReactions = includeReactions
        self.maxRetryAttempts = maxRetryAttempts
        self.backfillOnRestart = backfillOnRestart
    }
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
