import Foundation
import IMsgCore
import SQLite

/// Thin facade over IMsgCore (`MessageStore`, `MessageWatcher`, `MessageSender`)
/// that:
///   • normalizes the iMessage data model into the JSON shapes the relay/API/MCP layers consume,
///   • owns the watch loop and reconnects it on errors with backoff,
///   • persists the last-delivered rowid through `RelayQueue` so we resume cleanly after crashes.
///
/// Keeping this layer is worth the small abstraction tax because IMsgCore is
/// still pre-1.0; pinning all of its API touch-points behind a single class
/// makes future upstream churn a localized change.
actor ImsgClient {
    private let store: MessageStore
    private let watcher: MessageWatcher
    private let sender: MessageSender
    private let queue: RelayQueue
    private weak var relay: HTTPRelay?
    /// `nonisolated(unsafe)` matches the pattern in `HTTPRelay` —
    /// `TunnelManager` is `@unchecked Sendable` and we only read its
    /// `publicURL`/`isRunning` (both stored properties touched from
    /// the main thread on lifecycle changes). Used at event-encode
    /// time to attach absolute attachment URLs.
    nonisolated(unsafe) private weak var tunnel: TunnelManager?
    /// `ContactsResolver` is `@unchecked Sendable` and stateless from
    /// the actor's perspective (its in-memory cache is locked
    /// internally), so a plain `let` is enough — the compiler can
    /// prove cross-isolation safety from the type alone.
    private let contacts: ContactsResolver?

    private var watchTask: Task<Void, Never>?
    private var includeReactions: Bool

    static let cursorKey = "imsg.watch.since_rowid"

    init(queue: RelayQueue, relay: HTTPRelay, tunnel: TunnelManager? = nil, contacts: ContactsResolver? = nil) throws {
        self.store = try MessageStore()
        self.watcher = MessageWatcher(store: self.store)
        self.sender = MessageSender()
        self.queue = queue
        self.relay = relay
        self.tunnel = tunnel
        self.contacts = contacts
        self.includeReactions = AppConfigStore.shared.current.includeReactions
    }

    func startWatching() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            await self?.watchLoop()
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    private func watchLoop() async {
        // Prime the watch cursor based on the user's "backfill on
        // restart" preference (default off — relay only post-boot
        // events). See `primeCursor()` for the exact policy.
        primeCursor()

        var backoff: UInt64 = 1_000_000_000 // 1s
        while !Task.isCancelled {
            do {
                let since = queue.cursor(Self.cursorKey).flatMap(Int64.init)
                let config = MessageWatcherConfiguration(
                    debounceInterval: 0.25,
                    fallbackPollInterval: 5,
                    batchLimit: 100,
                    includeReactions: includeReactions
                )
                Log.imsg.info("watch loop starting (since=\(since ?? -1))")
                let stream = watcher.stream(chatID: nil, sinceRowID: since, configuration: config)
                for try await message in stream {
                    handle(message: message)
                    backoff = 1_000_000_000
                }
                Log.imsg.info("watch stream ended; reconnecting")
            } catch {
                Log.imsg.error("watch error: \(error.localizedDescription, privacy: .public)")
            }
            try? await Task.sleep(nanoseconds: backoff)
            backoff = min(backoff * 2, 30_000_000_000)
        }
    }

    /// Set the watch cursor based on the user's `backfillOnRestart`
    /// preference:
    ///
    /// * `backfillOnRestart == false` (default): always overwrite the
    ///   cursor with the current `MAX(ROWID)` from `chat.db`. The
    ///   watcher starts from "now" on every launch, so messages
    ///   received while the app was offline are skipped. This is the
    ///   right default — we don't want to dump multi-day history to
    ///   the user's endpoint after a quit period.
    ///
    /// * `backfillOnRestart == true`: only prime the cursor when one
    ///   isn't already stored. Subsequent launches resume from the
    ///   last-delivered rowID, so missed messages get relayed when
    ///   the app comes back up.
    ///
    /// The cursor itself is still updated on every delivered message
    /// in `handle(message:)`, so toggling the setting at runtime takes
    /// effect on the next restart without losing state.
    private func primeCursor() {
        let backfill = AppConfigStore.shared.current.backfillOnRestart
        if backfill, queue.cursor(Self.cursorKey) != nil {
            // Resume mode and we already have a checkpoint — leave it
            // alone so historical events between quit and relaunch
            // get streamed.
            return
        }
        let path = ("~/Library/Messages/chat.db" as NSString).expandingTildeInPath
        do {
            let db = try Connection(path, readonly: true)
            if let rowID = try db.scalar("SELECT MAX(ROWID) FROM message") as? Int64 {
                queue.setCursor(Self.cursorKey, String(rowID))
                Log.imsg.info("cursor primed at rowID \(rowID) (backfillOnRestart=\(backfill))")
            }
        } catch {
            // If the probe fails (FDA race, no Messages history, …)
            // we fall back to whatever cursor exists (or `nil`). The
            // worst-case path is a full backfill on first launch —
            // bad, but not a crash.
            Log.imsg.error("Failed to prime watch cursor: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handle(message: Message) {
        queue.setCursor(Self.cursorKey, String(message.rowID))

        let type: EventType
        if message.isReaction {
            type = .messageReaction
        } else if message.isFromMe {
            type = .messageSent
        } else {
            type = .messageReceived
        }

        // Compose the JSON payload. Start with the static message
        // encoder (enriched with contact names when the resolver has
        // access), then attach attachment metadata so remote endpoints
        // can pull the bytes via `GET /attachments/:msg_id/:index`.
        var payload = Self.encode(message, resolveName: nameResolver)
        if message.attachmentsCount > 0 {
            payload["attachments"] = encodeAttachments(for: message)
        }
        relay?.relay(type: type, payload: AnyCodable(payload))
    }

    /// Resolve and serialize a message's attachments into JSON-safe
    /// dicts for inclusion on outbound events. Each entry carries:
    ///   - `url`         — absolute URL when the tunnel is up, else absent
    ///   - `url_path`    — always present; relative path on the local API
    ///   - `filename`    — friendly name (transfer_name, fallback to filename)
    ///   - `mime_type`, `uti`, `size`, `is_sticker`, `missing`
    ///
    /// The remote endpoint can concatenate `server.callback_url +
    /// url_path` if it prefers, or just hit `url` directly.
    private func encodeAttachments(for message: Message) -> [[String: Any]] {
        let metas = (try? store.attachments(for: message.rowID)) ?? []
        let base = tunnel?.publicURL
        return metas.enumerated().map { index, meta -> [String: Any] in
            let path = "/attachments/\(message.rowID)/\(index)"
            let friendlyName = meta.transferName.isEmpty ? meta.filename : meta.transferName
            var entry: [String: Any] = [
                "url_path": path,
                "filename": friendlyName,
                "mime_type": meta.mimeType,
                "uti": meta.uti,
                "size": meta.totalBytes,
                "is_sticker": meta.isSticker,
                "missing": meta.missing
            ]
            if let base, !base.isEmpty {
                entry["url"] = base + path
            }
            if let converted = meta.convertedMimeType, !converted.isEmpty,
               converted != meta.mimeType {
                // When IMsgCore converts (e.g., HEIC → JPEG), surface
                // the served mime so consumers know what `url` will
                // actually deliver.
                entry["served_mime_type"] = converted
            }
            return entry
        }
    }

    /// Read the bytes of a single attachment by message rowid + zero-
    /// based index. Returns `nil` for unknown messages, out-of-range
    /// indices, missing files on disk, or paths outside the standard
    /// `~/Library/Messages/Attachments/` root (defensive against any
    /// upstream path-resolution drift).
    func attachmentBytes(messageID: Int64, index: Int) throws -> (data: Data, meta: AttachmentMeta, servedMime: String)? {
        let metas = try store.attachments(for: messageID, options: AttachmentQueryOptions(convertUnsupported: true))
        guard index >= 0, index < metas.count else { return nil }
        let meta = metas[index]

        // Prefer the converted file (e.g., HEIC → JPEG that web
        // browsers actually render); fall back to the original.
        let chosenPath = meta.convertedPath ?? meta.originalPath
        let servedMime = (meta.convertedMimeType?.isEmpty == false ? meta.convertedMimeType : nil) ?? meta.mimeType

        let expanded = (chosenPath as NSString).expandingTildeInPath

        // Defensive root check — never serve anything outside the
        // Messages attachments folder, no matter what chat.db says.
        let attachmentsRoot = ((("~/Library/Messages/Attachments/" as NSString).expandingTildeInPath) as NSString).standardizingPath
        let standardized = (expanded as NSString).standardizingPath
        guard standardized.hasPrefix(attachmentsRoot) else {
            Log.imsg.error("attachment refused: \(standardized, privacy: .public) outside attachments root")
            return nil
        }

        guard FileManager.default.fileExists(atPath: standardized) else {
            return nil
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: standardized))
        return (data, meta, servedMime)
    }

    // MARK: - Public API used by LocalAPIServer / MCPServer
    //
    // These return pre-serialized JSON `Data` rather than `[String: Any]`.
    // Rationale: `Any` does not conform to `Sendable`, and Swift 6 strict
    // concurrency rejects shipping it across actor boundaries. Serializing
    // here also avoids double-encoding at the API/MCP layers — they just
    // splat the bytes into the response body.

    func listChatsJSON(limit: Int) throws -> Data {
        let chats = try store.listChats(limit: limit)
        return try Self.encodeArray(chats.map(Self.encode))
    }

    func chatInfoJSON(id: Int64) throws -> Data? {
        guard let info = try store.chatInfo(chatID: id) else { return nil }
        let participants = (try? store.participants(chatID: id)) ?? []
        return try Self.encodeObject(Self.encode(info, participants: participants))
    }

    func historyJSON(chatID: Int64, limit: Int) throws -> Data {
        let messages = try store.messages(chatID: chatID, limit: limit)
        let resolver = nameResolver
        return try Self.encodeArray(messages.map { Self.encode($0, resolveName: resolver) })
    }

    func searchJSON(query: String, match: String = "contains", limit: Int = 50) throws -> Data {
        let messages = try store.searchMessages(query: query, match: match, limit: limit)
        let resolver = nameResolver
        return try Self.encodeArray(messages.map { Self.encode($0, resolveName: resolver) })
    }

    /// Snapshot of the contacts resolver as a plain closure. Used by
    /// both the relay's event-encoder (line ~150) and the bulk REST
    /// encoders above so they all surface `sender_name` consistently.
    /// Returning `nil` here means "no enrichment" (no resolver wired
    /// in, or the user hasn't granted Contacts access yet).
    private var nameResolver: ((String) -> String?)? {
        guard let contacts else { return nil }
        return { handle in contacts.name(for: handle) }
    }

    func send(
        to recipient: String,
        text: String,
        attachmentPath: String? = nil,
        chatID: Int64? = nil,
        service: String = "auto"
    ) throws {
        var options = MessageSendOptions(
            recipient: recipient,
            text: text,
            attachmentPath: attachmentPath ?? "",
            service: MessageService(rawValue: service) ?? .auto
        )
        if let chatID, let info = try store.chatInfo(chatID: chatID) {
            options.chatGUID = info.guid
            options.chatIdentifier = info.identifier
        }
        try sender.send(options)
    }

    // MARK: - JSON encoders

    static func encode(_ chat: Chat) -> [String: Any] {
        [
            "id": chat.id,
            "identifier": chat.identifier,
            "name": chat.name,
            "service": chat.service,
            "last_message_at": ISO8601DateFormatter.ms.string(from: chat.lastMessageAt),
            "account_id": chat.accountID ?? "",
            "account_login": chat.accountLogin ?? "",
            "last_addressed_handle": chat.lastAddressedHandle ?? ""
        ]
    }

    static func encode(_ info: ChatInfo, participants: [String]) -> [String: Any] {
        [
            "id": info.id,
            "identifier": info.identifier,
            "guid": info.guid,
            "name": info.name,
            "service": info.service,
            "participants": participants,
            "is_group": participants.count > 1,
            "account_id": info.accountID ?? "",
            "account_login": info.accountLogin ?? "",
            "last_addressed_handle": info.lastAddressedHandle ?? ""
        ]
    }

    private static func encodeArray(_ rows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: rows, options: [.fragmentsAllowed])
    }

    private static func encodeObject(_ row: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: row, options: [.fragmentsAllowed])
    }

    static func encode(_ message: Message, resolveName: ((String) -> String?)? = nil) -> [String: Any] {
        var out: [String: Any] = [
            "id": message.rowID,
            "chat_id": message.chatID,
            "guid": message.guid,
            "sender": message.sender,
            "text": message.text,
            "created_at": ISO8601DateFormatter.ms.string(from: message.date),
            "is_from_me": message.isFromMe,
            "service": message.service,
            "attachments_count": message.attachmentsCount
        ]
        if let resolveName, let name = resolveName(message.sender), !name.isEmpty {
            out["sender_name"] = name
        }
        if let replyToGUID = message.replyToGUID { out["reply_to_guid"] = replyToGUID }
        if let replyToText = message.replyToText { out["reply_to_text"] = replyToText }
        if let replyToSender = message.replyToSender {
            out["reply_to_sender"] = replyToSender
            if let resolveName, let name = resolveName(replyToSender), !name.isEmpty {
                out["reply_to_sender_name"] = name
            }
        }
        if let destination = message.destinationCallerID { out["destination_caller_id"] = destination }

        if message.isReaction {
            out["is_reaction"] = true
            if let type = message.reactionType {
                out["reaction_type"] = type.name
                out["reaction_emoji"] = type.emoji
            }
            if let add = message.isReactionAdd { out["is_reaction_add"] = add }
            if let target = message.reactedToGUID { out["reacted_to_guid"] = target }
        }
        return out
    }
}
