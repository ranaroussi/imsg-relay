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

    private var watchTask: Task<Void, Never>?
    private var includeReactions: Bool

    static let cursorKey = "imsg.watch.since_rowid"

    init(queue: RelayQueue, relay: HTTPRelay) throws {
        self.store = try MessageStore()
        self.watcher = MessageWatcher(store: self.store)
        self.sender = MessageSender()
        self.queue = queue
        self.relay = relay
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
        // On first launch (no cursor stored), prime it to the current
        // MAX(ROWID) in chat.db so the watcher starts from "now"
        // instead of replaying tens of thousands of historical
        // messages. The relay is for going-forward events; historical
        // messages remain queryable via the HTTP and MCP APIs.
        primeCursorIfNeeded()

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

    /// Open chat.db read-only and store the current `MAX(ROWID)` as the
    /// watch cursor. Cheap one-shot query that avoids streaming the
    /// whole message history on first launch.
    private func primeCursorIfNeeded() {
        guard queue.cursor(Self.cursorKey) == nil else { return }
        let path = ("~/Library/Messages/chat.db" as NSString).expandingTildeInPath
        do {
            let db = try Connection(path, readonly: true)
            if let rowID = try db.scalar("SELECT MAX(ROWID) FROM message") as? Int64 {
                queue.setCursor(Self.cursorKey, String(rowID))
                Log.imsg.info("first launch — cursor primed at rowID \(rowID)")
            }
        } catch {
            // If the probe fails (FDA race, no Messages history, …)
            // we fall back to `nil`, which means the watcher will
            // backfill from the start. That's a worse path but is at
            // least not a crash.
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
        // Project to a JSON-safe dict before sending across the actor hop;
        // `[String: Any]` isn't Sendable but the relay only needs the
        // value wrapped in `AnyCodable`, which captures everything by value.
        let payload = AnyCodable(Self.encode(message))
        relay?.relay(type: type, payload: payload)
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
        return try Self.encodeArray(messages.map(Self.encode))
    }

    func searchJSON(query: String, match: String = "contains", limit: Int = 50) throws -> Data {
        let messages = try store.searchMessages(query: query, match: match, limit: limit)
        return try Self.encodeArray(messages.map(Self.encode))
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

    static func encode(_ message: Message) -> [String: Any] {
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
        if let replyToGUID = message.replyToGUID { out["reply_to_guid"] = replyToGUID }
        if let replyToText = message.replyToText { out["reply_to_text"] = replyToText }
        if let replyToSender = message.replyToSender { out["reply_to_sender"] = replyToSender }
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
