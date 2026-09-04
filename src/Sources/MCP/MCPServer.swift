import Foundation
import MCP

/// MCP service backed by `ImsgClient`. Same tool surface regardless of
/// transport. `ImsgRelay --mcp` keeps one instance alive on stdio. HTTP
/// requests use `handleStatelessHTTPRequest`, which creates an isolated
/// server and transport for every request.
///
/// The MCP server identifier stays as the kebab-case "imsg-relay"
/// because that's a machine-readable name baked into client configs.
///
/// Stdio and HTTP modes run as two distinct process modes on the same
/// binary — keeping the menu bar app off stdio avoids fighting macOS
/// for stdin/stdout while the GUI is up.
final class MCPService {
    private let imsg: ImsgClient
    private let server: Server
    private let transport: any Transport

    init(imsg: ImsgClient, transport: any Transport) {
        self.imsg = imsg
        self.transport = transport
        self.server = Server(
            name: "imsg-relay",
            version: Self.versionString(),
            capabilities: .init(tools: .init(listChanged: false))
        )
    }

    func run() async throws {
        try await start()
        await server.waitUntilCompleted()
    }

    /// Process one request with completely isolated protocol state.
    ///
    /// A `StatelessHTTPServerTransport` does not isolate the SDK `Server`
    /// attached to it. Reusing one Server therefore makes the second client
    /// fail its initialize request with "Server is already initialized".
    /// Creating both objects per request also permits concurrent clients.
    static func handleStatelessHTTPRequest(
        _ request: MCP.HTTPRequest,
        imsg: ImsgClient
    ) async -> MCP.HTTPResponse {
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                OriginValidator.disabled,
                AcceptHeaderValidator(mode: .jsonOnly),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
            ])
        )
        let service = MCPService(imsg: imsg, transport: transport)

        do {
            try await service.start()
            let response = await transport.handleRequest(request)
            await service.stop()
            return response
        } catch {
            await service.stop()
            return .error(
                statusCode: 500,
                .internalError("Failed to process MCP request: \(error.localizedDescription)")
            )
        }
    }

    private func start() async throws {
        await registerTools()
        try await server.start(transport: transport)
    }

    private func stop() async {
        await server.stop()
    }

    // MARK: - Tools

    private func registerTools() async {
        let imsg = self.imsg

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: Self.toolDefinitions)
        }

        await server.withMethodHandler(CallTool.self) { params in
            do {
                switch params.name {
                case "imsg_list_chats":
                    let limit = Self.intArg(params, "limit", default: 50)
                    let body = try await imsg.listChatsJSON(limit: limit)
                    return .init(content: [.text(text: Self.utf8(body), annotations: nil, _meta: nil)], isError: false)

                case "imsg_get_chat":
                    guard let id = Self.intArg(params, "chat_id") else {
                        return Self.err("missing chat_id")
                    }
                    guard let body = try await imsg.chatInfoJSON(id: Int64(id)) else {
                        return Self.err("chat not found")
                    }
                    return .init(content: [.text(text: Self.utf8(body), annotations: nil, _meta: nil)], isError: false)

                case "imsg_get_history":
                    guard let id = Self.intArg(params, "chat_id") else {
                        return Self.err("missing chat_id")
                    }
                    let limit = Self.intArg(params, "limit", default: 50)
                    let body = try await imsg.historyJSON(chatID: Int64(id), limit: limit)
                    return .init(content: [.text(text: Self.utf8(body), annotations: nil, _meta: nil)], isError: false)

                case "imsg_search_messages":
                    guard let query = Self.stringArg(params, "query") else {
                        return Self.err("missing query")
                    }
                    let match = Self.stringArg(params, "match") ?? "contains"
                    let limit = Self.intArg(params, "limit", default: 50)
                    let body = try await imsg.searchJSON(query: query, match: match, limit: limit)
                    return .init(content: [.text(text: Self.utf8(body), annotations: nil, _meta: nil)], isError: false)

                case "imsg_send_message":
                    guard let to = Self.stringArg(params, "to"),
                          let text = Self.stringArg(params, "text") else {
                        return Self.err("missing to/text")
                    }
                    let service = Self.stringArg(params, "service") ?? "auto"
                    let chatID = Self.intArg(params, "chat_id").map(Int64.init)
                    try await imsg.send(to: to, text: text, chatID: chatID, service: service)
                    return .init(content: [.text(text: "{\"queued\":true}", annotations: nil, _meta: nil)], isError: false)

                case "imsg_send_attachment":
                    guard let to = Self.stringArg(params, "to") else {
                        return Self.err("missing to")
                    }
                    let text = Self.stringArg(params, "text") ?? ""
                    let chatID = Self.intArg(params, "chat_id").map(Int64.init)

                    // Two acceptable input shapes:
                    //   1. content_base64 + filename  — remote agents
                    //      (the only viable shape over HTTP MCP).
                    //   2. attachment_path            — legacy / stdio
                    //      mode where the agent shares this Mac's
                    //      filesystem.
                    let finalPath: String
                    var stagedPath: String? = nil
                    if let b64 = Self.stringArg(params, "content_base64"),
                       let rawName = Self.stringArg(params, "filename"),
                       let bytes = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
                        let safeName = LocalAPIServer.sanitizeFilename(rawName)
                        let path = try LocalAPIServer.stageOutboundAttachment(data: bytes, filename: safeName)
                        stagedPath = path
                        finalPath = path
                    } else if let path = Self.stringArg(params, "attachment_path") {
                        finalPath = path
                    } else {
                        return Self.err("must provide either (content_base64 + filename) or attachment_path")
                    }
                    defer { if let p = stagedPath { try? FileManager.default.removeItem(atPath: p) } }

                    try await imsg.send(to: to, text: text, attachmentPath: finalPath, chatID: chatID)
                    return .init(content: [.text(text: "{\"queued\":true}", annotations: nil, _meta: nil)], isError: false)

                case "imsg_get_status":
                    let config = AppConfigStore.shared.current
                    let payload: [String: Any] = [
                        "mcp_connected": true,
                        "database_access": Permissions.hasFullDiskAccess(),
                        "local_api_port": config.localAPIPort,
                        "outbound_relay_enabled": config.relayEnabled,
                        "identifier": config.serverIdentifier,
                        "endpoint": config.serverEndpoint,
                        "tunnel_enabled": config.tunnelEnabled
                    ]
                    let json = try JSONSerialization.data(withJSONObject: payload)
                    return .init(content: [.text(text: Self.utf8(json), annotations: nil, _meta: nil)], isError: false)

                default:
                    return Self.err("unknown tool: \(params.name)")
                }
            } catch {
                return Self.err(error.localizedDescription)
            }
        }
    }

    // MARK: - Tool catalog

    /// Explicit annotations keep read-only queries usable when Codex runs
    /// with a noninteractive approval policy. MCP defaults unannotated tools
    /// to mutating and potentially destructive, which incorrectly approval-
    /// gates status and history reads.
    nonisolated private static let messageQueryAnnotations = Tool.Annotations(
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    nonisolated private static let messageSendAnnotations = Tool.Annotations(
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true
    )

    nonisolated private static let toolDefinitions: [Tool] = [
        Tool(
            name: "imsg_list_chats",
            description: "List recent iMessage chats, most-recent first.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object(["type": .string("integer"), "description": .string("Max chats to return (default 50)")])
                ])
            ]),
            annotations: messageQueryAnnotations
        ),
        Tool(
            name: "imsg_get_chat",
            description: "Fetch a single chat (with participants) by numeric chat_id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "chat_id": .object(["type": .string("integer")])
                ]),
                "required": .array([.string("chat_id")])
            ]),
            annotations: messageQueryAnnotations
        ),
        Tool(
            name: "imsg_get_history",
            description: "Fetch recent messages for a chat.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "chat_id": .object(["type": .string("integer")]),
                    "limit": .object(["type": .string("integer")])
                ]),
                "required": .array([.string("chat_id")])
            ]),
            annotations: messageQueryAnnotations
        ),
        Tool(
            name: "imsg_search_messages",
            description: "Full-text search across local message history.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string")]),
                    "match": .object(["type": .string("string"), "description": .string("contains | exact")]),
                    "limit": .object(["type": .string("integer")])
                ]),
                "required": .array([.string("query")])
            ]),
            annotations: messageQueryAnnotations
        ),
        Tool(
            name: "imsg_send_message",
            description: "Send a text message via Messages.app. Pass either to (phone/email) or chat_id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "to": .object(["type": .string("string")]),
                    "text": .object(["type": .string("string")]),
                    "chat_id": .object(["type": .string("integer")]),
                    "service": .object(["type": .string("string"), "description": .string("auto | imessage | sms")])
                ]),
                "required": .array([.string("to"), .string("text")])
            ]),
            annotations: messageSendAnnotations
        ),
        Tool(
            name: "imsg_send_attachment",
            description: """
                Send a file attachment via Messages.app. Provide the file as base64-encoded \
                content_base64 + filename (preferred for HTTP/remote MCP clients), or as an \
                absolute attachment_path on the host Mac (stdio mode only).
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "to": .object(["type": .string("string")]),
                    "text": .object(["type": .string("string"), "description": .string("Optional caption sent with the file")]),
                    "chat_id": .object(["type": .string("integer")]),
                    "content_base64": .object(["type": .string("string"), "description": .string("File bytes, base64-encoded")]),
                    "filename": .object(["type": .string("string"), "description": .string("Filename with extension, used when content_base64 is provided")]),
                    "attachment_path": .object(["type": .string("string"), "description": .string("Absolute path on the host Mac (stdio MCP only)")])
                ]),
                "required": .array([.string("to")])
            ]),
            annotations: messageSendAnnotations
        ),
        Tool(
            name: "imsg_get_status",
            description: "Report MCP connectivity and database access separately from optional outbound relay and tunnel state.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:])
            ]),
            annotations: messageQueryAnnotations
        )
    ]

    // MARK: - Helpers

    // All argument-extraction and response-shaping helpers are
    // `nonisolated` so the MCP tool handler closure (which runs outside
    // the main actor) can call them without hopping back. Pure value
    // transforms; no state.
    nonisolated private static func versionString() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    nonisolated private static func intArg(_ params: CallTool.Parameters, _ key: String, default fallback: Int) -> Int {
        intArg(params, key) ?? fallback
    }

    nonisolated private static func intArg(_ params: CallTool.Parameters, _ key: String) -> Int? {
        guard let arg = params.arguments?[key] else { return nil }
        switch arg {
        case .int(let v): return Int(v)
        case .double(let v): return Int(v)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    nonisolated private static func stringArg(_ params: CallTool.Parameters, _ key: String) -> String? {
        guard let arg = params.arguments?[key] else { return nil }
        if case .string(let s) = arg { return s }
        return nil
    }

    nonisolated private static func utf8(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? "{}"
    }

    nonisolated private static func err(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}
