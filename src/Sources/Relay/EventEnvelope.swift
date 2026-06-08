import Foundation

/// Wire format for every event the relay sends to the remote server.
/// Matches the JSON shape in the PRD exactly so external consumers can
/// parse without surprise.
struct EventEnvelope: Codable, Sendable {
    struct Server: Codable, Sendable {
        var identifier: String
        var endpoint: String
        /// Current Cloudflare Tunnel URL, or empty if the tunnel is down.
        /// Pulled fresh at envelope-build time so URL rotations are visible
        /// to the remote server immediately.
        var callback_url: String
    }

    struct Event: Codable, Sendable {
        var type: String
        var timestamp: String
    }

    var server: Server
    var event: Event
    var data: AnyCodable

    init(type: EventType, data: AnyCodable, server: Server) {
        self.server = server
        self.event = Event(type: type.rawValue, timestamp: ISO8601DateFormatter.ms.string(from: Date()))
        self.data = data
    }
}

/// Strongly-typed list of every event type the PRD enumerates.
/// Keeping this exhaustive prevents typos at call sites.
enum EventType: String, Sendable, CaseIterable {
    case messageReceived  = "message.received"
    case messageSent      = "message.sent"
    case messageDelivered = "message.delivered"
    case messageRead      = "message.read"
    case messageReaction  = "message.reaction"
    case messageEdited    = "message.edited"
    case messageUnsent    = "message.unsent"

    case chatCreated      = "chat.created"
    case chatUpdated      = "chat.updated"

    case attachmentReceived = "attachment.received"
    case attachmentSent     = "attachment.sent"

    case relayStarted    = "relay.started"
    case relayStopped    = "relay.stopped"
    case relayError      = "relay.error"
    case tunnelConnected = "tunnel.connected"
    case tunnelDisconnected = "tunnel.disconnected"
    case tunnelChanged   = "tunnel.changed"
}

/// Minimal type-erased JSON container used by `EventEnvelope.data`.
/// We avoid pulling in a heavier JSON library because the payloads here
/// are tiny and the boundary is well-defined.
///
/// Marked `@unchecked Sendable` because the boxed value is always a
/// JSON-shaped value tree (numbers, strings, bools, arrays, dictionaries
/// keyed by `String`). Callers must not stuff reference types in here.
struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = NSNull(); return }
        if let v = try? c.decode(Bool.self)    { value = v; return }
        if let v = try? c.decode(Int64.self)   { value = v; return }
        if let v = try? c.decode(Double.self)  { value = v; return }
        if let v = try? c.decode(String.self)  { value = v; return }
        if let v = try? c.decode([AnyCodable].self) { value = v.map(\.value); return }
        if let v = try? c.decode([String: AnyCodable].self) {
            value = v.mapValues(\.value); return
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let v as Bool:   try c.encode(v)
        case let v as Int:    try c.encode(v)
        case let v as Int64:  try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [Any]:
            try c.encode(v.map(AnyCodable.init))
        case let v as [String: Any]:
            try c.encode(v.mapValues(AnyCodable.init))
        case let v as Date:
            try c.encode(ISO8601DateFormatter.ms.string(from: v))
        default:
            // Best-effort: emit the description so we never block sending.
            try c.encode(String(describing: value))
        }
    }
}

extension ISO8601DateFormatter {
    /// Millisecond-precision ISO-8601 used everywhere on the wire.
    /// `ISO8601DateFormatter` is documented thread-safe for *use* once
    /// configured, so a single shared instance is safe; we just have to
    /// tell Swift's strict-concurrency checker that we know.
    nonisolated(unsafe) static let ms: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
