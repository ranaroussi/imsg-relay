import Foundation
import MCP

/// MCP service backed by `ImsgClient`. Same tool surface regardless of
/// transport — the menu bar app boots one of these on a
/// `StatelessHTTPServerTransport` (reachable via the Cloudflare Tunnel),
/// and `ImsgRelay --mcp` boots a second instance on a `StdioTransport`
/// for local Claude Desktop integration.
///
/// The MCP server identifier stays as the kebab-case "imsg-relay"
/// because that's a machine-readable name baked into client configs.
///
/// Stdio and HTTP modes run as two distinct process modes on the same
/// binary — keeping the menu bar app off stdio avoids fighting macOS
/// for stdin/stdout while the GUI is up.
@MainActor
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
        await registerTools()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
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
                    return .init(content: [.text(Self.utf8(body))], isError: false)

                case "imsg_get_chat":
                    guard let id = Self.intArg(params, "chat_id") else {
                        return Self.err("missing chat_id")
                    }
                    guard let body = try await imsg.chatInfoJSON(id: Int64(id)) else {
                        return Self.err("chat not found")
                    }
                    return .init(content: [.text(Self.utf8(body))], isError: false)

                case "imsg_get_history":
                    guard let id = Self.intArg(params, "chat_id") else {
                        return Self.err("missing chat_id")
                    }
                    let limit = Self.intArg(params, "limit", default: 50)
                    let body = try await imsg.historyJSON(chatID: Int64(id), limit: limit)
                    return .init(content: [.text(Self.utf8(body))], isError: false)

                case "imsg_search_messages":
                    guard let query = Self.stringArg(params, "query") else {
                        return Self.err("missing query")
                    }
                    let match = Self.stringArg(params, "match") ?? "contains"
                    let limit = Self.intArg(params, "limit", default: 50)
                    let body = try await imsg.searchJSON(query: query, match: match, limit: limit)
                    return .init(content: [.text(Self.utf8(body))], isError: false)

                case "imsg_send_message":
                    guard let to = Self.stringArg(params, "to"),
                          let text = Self.stringArg(params, "text") else {
                        return Self.err("missing to/text")
                    }
                    let service = Self.stringArg(params, "service") ?? "auto"
                    let chatID = Self.intArg(params, "chat_id").map(Int64.init)
                    try await imsg.send(to: to, text: text, chatID: chatID, service: service)
                    return .init(content: [.text("{\"queued\":true}")], isError: false)

                case "imsg_send_attachment":
                    guard let to = Self.stringArg(params, "to"),
                          let path = Self.stringArg(params, "attachment_path") else {
                        return Self.err("missing to/attachment_path")
                    }
                    let text = Self.stringArg(params, "text") ?? ""
                    try await imsg.send(to: to, text: text, attachmentPath: path)
                    return .init(content: [.text("{\"queued\":true}")], isError: false)

                case "imsg_get_status":
                    let config = AppConfigStore.shared.current
                    let payload: [String: Any] = [
                        "identifier": config.serverIdentifier,
                        "endpoint": config.serverEndpoint,
                        "tunnel_enabled": config.tunnelEnabled
                    ]
                    let json = try JSONSerialization.data(withJSONObject: payload)
                    return .init(content: [.text(Self.utf8(json))], isError: false)

                default:
                    return Self.err("unknown tool: \(params.name)")
                }
            } catch {
                return Self.err(error.localizedDescription)
            }
        }
    }

    // MARK: - Tool catalog

    nonisolated private static let toolDefinitions: [Tool] = [
        Tool(
            name: "imsg_list_chats",
            description: "List recent iMessage chats, most-recent first.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object(["type": .string("integer"), "description": .string("Max chats to return (default 50)")])
                ])
            ])
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
            ])
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
            ])
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
            ])
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
            ])
        ),
        Tool(
            name: "imsg_send_attachment",
            description: "Send a file attachment via Messages.app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "to": .object(["type": .string("string")]),
                    "attachment_path": .object(["type": .string("string")]),
                    "text": .object(["type": .string("string")])
                ]),
                "required": .array([.string("to"), .string("attachment_path")])
            ])
        ),
        Tool(
            name: "imsg_get_status",
            description: "Report relay configuration (identifier, endpoint, tunnel state).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:])
            ])
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
        .init(content: [.text(text: message)], isError: true)
    }
}
