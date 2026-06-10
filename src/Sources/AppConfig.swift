import Foundation

/// How the Cloudflare Tunnel is fronted.
///
/// `.quick` runs `cloudflared tunnel --url http://localhost:<port>` and
/// gets back an ephemeral `*.trycloudflare.com` URL — zero CF account
/// needed, but the URL rotates on every restart. Right default for
/// first-launch UX and for backends that can re-read `callback_url`
/// out of every event.
///
/// `.named` runs `cloudflared tunnel run --token <token>` against a
/// connector configured in the user's Cloudflare Zero Trust dashboard.
/// The hostname is stable (`mcp.yourcompany.com`), so MCP clients that
/// hardcode the URL keep working across restarts.
enum TunnelMode: String, Codable, Sendable, Equatable, CaseIterable {
    case quick
    case named
}

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

    /// Selects between the ephemeral `trycloudflare.com` URL and a
    /// named tunnel bound to a domain on the user's CF account.
    /// See `TunnelMode` for the trade-off.
    var tunnelMode: TunnelMode

    /// Cloudflare Tunnel connector token (the long `eyJh...` string
    /// you copy out of the Zero Trust dashboard after creating a
    /// tunnel). Only used when `tunnelMode == .named`. Treated as a
    /// secret — rendered as a `SecureField` in Settings.
    var tunnelToken: String

    /// The public hostname configured against the named tunnel
    /// (e.g. `mcp.yourcompany.com`). Used as `server.callback_url` on
    /// outbound events and displayed in Settings. Schema is normalized
    /// to bare hostname (no `https://` prefix) when written; we add
    /// the scheme at display / event-emission time.
    var tunnelHostname: String

    // MARK: - Attachments

    /// When true, the `/attachments/:msg_id/:index` route is served
    /// without bearer-token authentication so any caller can fetch
    /// attachment bytes by URL. Off by default.
    var attachmentsPublic: Bool

    // MARK: - Local archive

    /// When true, every inbound message is mirrored to disk under
    /// `localSavePath` in addition to being relayed over HTTP.
    var localSaveEnabled: Bool

    /// Root directory for the local archive. Each message gets a
    /// `<rowID>/` sub-folder containing `message.json`, `MESSAGE.txt`,
    /// and `attachments/`.
    var localSavePath: String

    // MARK: - Filter

    /// If non-empty, only messages whose sender matches one of these
    /// handles are processed (after normalization). All other
    /// messages are silently dropped.
    var whitelistHandles: [String]

    /// Messages whose sender matches any of these handles are silently
    /// dropped (unless the whitelist is non-empty, in which case the
    /// whitelist wins).
    var blacklistHandles: [String]

    static let `default` = AppConfig(
        serverIdentifier: "",
        serverEndpoint: "",
        bearerToken: "",
        localAPIPort: 7878,
        mcpPort: 7879,
        tunnelEnabled: false,
        includeReactions: true,
        maxRetryAttempts: 12,
        backfillOnRestart: false,
        tunnelMode: .quick,
        tunnelToken: "",
        tunnelHostname: "",
        attachmentsPublic: false,
        localSaveEnabled: false,
        localSavePath: "",
        whitelistHandles: [],
        blacklistHandles: []
    )

    // Custom decoder so we can extend `AppConfig` with new fields
    // without invalidating already-persisted configs. Missing keys
    // fall back to the `.default` value's field rather than throwing,
    // which is what users want — adding a new toggle shouldn't reset
    // their endpoint / token / etc.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig.default
        self.serverIdentifier  = (try? c.decode(String.self,     forKey: .serverIdentifier))  ?? d.serverIdentifier
        self.serverEndpoint    = (try? c.decode(String.self,     forKey: .serverEndpoint))    ?? d.serverEndpoint
        self.bearerToken       = (try? c.decode(String.self,     forKey: .bearerToken))       ?? d.bearerToken
        self.localAPIPort      = (try? c.decode(Int.self,        forKey: .localAPIPort))      ?? d.localAPIPort
        self.mcpPort           = (try? c.decode(Int.self,        forKey: .mcpPort))           ?? d.mcpPort
        self.tunnelEnabled     = (try? c.decode(Bool.self,       forKey: .tunnelEnabled))     ?? d.tunnelEnabled
        self.includeReactions  = (try? c.decode(Bool.self,       forKey: .includeReactions))  ?? d.includeReactions
        self.maxRetryAttempts  = (try? c.decode(Int.self,        forKey: .maxRetryAttempts))  ?? d.maxRetryAttempts
        self.backfillOnRestart = (try? c.decode(Bool.self,       forKey: .backfillOnRestart)) ?? d.backfillOnRestart
        self.tunnelMode        = (try? c.decode(TunnelMode.self, forKey: .tunnelMode))        ?? d.tunnelMode
        self.tunnelToken       = (try? c.decode(String.self,     forKey: .tunnelToken))       ?? d.tunnelToken
        self.tunnelHostname    = (try? c.decode(String.self,     forKey: .tunnelHostname))    ?? d.tunnelHostname
        self.attachmentsPublic = (try? c.decode(Bool.self,       forKey: .attachmentsPublic)) ?? d.attachmentsPublic
        self.localSaveEnabled  = (try? c.decode(Bool.self,       forKey: .localSaveEnabled))  ?? d.localSaveEnabled
        self.localSavePath     = (try? c.decode(String.self,     forKey: .localSavePath))     ?? d.localSavePath
        self.whitelistHandles  = (try? c.decode([String].self,  forKey: .whitelistHandles))  ?? d.whitelistHandles
        self.blacklistHandles  = (try? c.decode([String].self,  forKey: .blacklistHandles))  ?? d.blacklistHandles
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
        backfillOnRestart: Bool,
        tunnelMode: TunnelMode,
        tunnelToken: String,
        tunnelHostname: String,
        attachmentsPublic: Bool = false,
        localSaveEnabled: Bool = false,
        localSavePath: String = "",
        whitelistHandles: [String] = [],
        blacklistHandles: [String] = []
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
        self.tunnelMode = tunnelMode
        self.tunnelToken = tunnelToken
        self.tunnelHostname = tunnelHostname
        self.attachmentsPublic = attachmentsPublic
        self.localSaveEnabled = localSaveEnabled
        self.localSavePath = localSavePath
        self.whitelistHandles = whitelistHandles
        self.blacklistHandles = blacklistHandles
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
