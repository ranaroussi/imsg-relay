import Foundation
import Hummingbird
import HTTPTypes
import MCP

/// Local HTTP API as specified in the PRD.
///
///   GET  /health
///   GET  /status
///   GET  /stats
///   GET  /chats
///   GET  /chats/{id}
///   GET  /history?chat_id=&limit=&before=&after=
///   GET  /search/messages?q=&match=&limit=
///   POST /send                  { to, text, chat_id?, service?, attachment_url? }
///   POST /send/attachment       multipart: file + form fields
///
/// Bearer-token auth is enforced when `AppConfigStore.shared.current.bearerToken`
/// is non-empty. The relay is meant to sit behind a Cloudflare Tunnel so
/// "leave the token blank to disable auth" is intentional for dev only.
final class LocalAPIServer: @unchecked Sendable {
    private let port: Int
    private weak var imsg: ImsgClient?
    private weak var tunnel: TunnelManager?
    private weak var queue: RelayQueue?
    private let mcpTransport: StatelessHTTPServerTransport?
    private var task: Task<Void, Error>?

    init(
        port: Int,
        imsg: ImsgClient,
        tunnel: TunnelManager,
        queue: RelayQueue,
        mcpTransport: StatelessHTTPServerTransport? = nil
    ) {
        self.port = port
        self.imsg = imsg
        self.tunnel = tunnel
        self.queue = queue
        self.mcpTransport = mcpTransport
    }

    func start() {
        let imsg = self.imsg
        let tunnel = self.tunnel
        let queue = self.queue
        let mcpTransport = self.mcpTransport
        let port = self.port

        task = Task.detached {
            let router = Router()
            router.add(middleware: BearerAuthMiddleware())

            router.get("/health") { _, _ -> Response in
                Self.json(["ok": true])
            }
            router.get("/status") { _, _ -> Response in
                let config = AppConfigStore.shared.current
                return Self.json([
                    "identifier": config.serverIdentifier,
                    "endpoint": config.serverEndpoint,
                    "tunnel_url": tunnel?.publicURL ?? "",
                    "tunnel_running": tunnel?.isRunning ?? false
                ])
            }
            router.get("/stats") { _, _ -> Response in
                let stats = queue?.stats() ?? (0, 0)
                return Self.json(["queued": stats.0, "dead": stats.1])
            }
            router.get("/chats") { req, _ -> Response in
                let limit = Self.intParam(req, "limit", default: 50)
                guard let body = try await imsg?.listChatsJSON(limit: limit) else {
                    return Self.jsonData("[]")
                }
                return Self.jsonRaw(body, key: "chats")
            }
            router.get("/chats/:id") { req, context -> Response in
                guard let raw = context.parameters.get("id"), let id = Int64(raw) else {
                    throw HTTPError(.badRequest)
                }
                guard let body = try await imsg?.chatInfoJSON(id: id) else {
                    throw HTTPError(.notFound)
                }
                return Self.jsonData(body)
            }
            router.get("/history") { req, _ -> Response in
                guard let raw = req.uri.queryParameters["chat_id"], let id = Int64(raw) else {
                    throw HTTPError(.badRequest)
                }
                let limit = Self.intParam(req, "limit", default: 50)
                guard let body = try await imsg?.historyJSON(chatID: id, limit: limit) else {
                    return Self.jsonData("[]")
                }
                return Self.jsonRaw(body, key: "messages")
            }
            router.get("/search/messages") { req, _ -> Response in
                guard let q = req.uri.queryParameters["q"], !q.isEmpty else {
                    throw HTTPError(.badRequest)
                }
                let match = String(req.uri.queryParameters["match"] ?? "contains")
                let limit = Self.intParam(req, "limit", default: 50)
                guard let body = try await imsg?.searchJSON(query: String(q), match: match, limit: limit) else {
                    return Self.jsonData("[]")
                }
                return Self.jsonRaw(body, key: "messages")
            }

            // Stream a single attachment by (message_id, index). The
            // pair is what `data.attachments[i].url_path` on outbound
            // events points to, so remote endpoints can fetch any file
            // referenced by a relayed message. Bearer-auth protected.
            router.get("/attachments/:msg_id/:index") { _, context -> Response in
                guard let msgRaw = context.parameters.get("msg_id"),
                      let messageID = Int64(msgRaw),
                      let idxRaw = context.parameters.get("index"),
                      let index = Int(idxRaw) else {
                    throw HTTPError(.badRequest)
                }
                guard let imsg else { throw HTTPError(.serviceUnavailable) }
                guard let result = try await imsg.attachmentBytes(messageID: messageID, index: index) else {
                    throw HTTPError(.notFound)
                }
                return Self.attachmentResponse(
                    data: result.data,
                    mimeType: result.servedMime,
                    filename: result.meta.transferName.isEmpty ? result.meta.filename : result.meta.transferName
                )
            }
            router.post("/send") { req, _ -> Response in
                let body = try await req.body.collect(upTo: 1_048_576) // 1 MB
                let payload = try JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any] ?? [:]
                guard let to = payload["to"] as? String, let text = payload["text"] as? String else {
                    throw HTTPError(.badRequest)
                }
                let chatID = (payload["chat_id"] as? NSNumber)?.int64Value
                let service = payload["service"] as? String ?? "auto"
                try await imsg?.send(to: to, text: text, chatID: chatID, service: service)
                return Self.json(["queued": true])
            }

            // MCP over HTTP. The Hummingbird request gets adapted into
            // the SDK's framework-agnostic `MCP.HTTPRequest`, handed to
            // `StatelessHTTPServerTransport`, and the resulting
            // `MCP.HTTPResponse` is adapted back. The transport bridges
            // into the SDK `Server` boot from `AppDelegate`, so the
            // same tools that work over stdio are reachable here.
            router.post("/mcp") { req, _ -> Response in
                guard let transport = mcpTransport else {
                    throw HTTPError(.serviceUnavailable)
                }
                let body = try await req.body.collect(upTo: 1_048_576)
                let mcpRequest = Self.makeMCPRequest(req: req, body: Data(buffer: body))
                let mcpResponse = await transport.handleRequest(mcpRequest)
                return Self.makeHummingbirdResponse(from: mcpResponse)
            }

            let app = Application(
                router: router,
                configuration: .init(address: .hostname("127.0.0.1", port: port))
            )
            Log.api.info("Local API listening on 127.0.0.1:\(port)")
            try await app.runService()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private static func json(_ object: Any) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
        return jsonData(data)
    }

    /// Wraps a pre-serialized JSON array `Data` under a top-level key,
    /// e.g. `{"messages": [...]}`. We do the wrap as a string-splice so we
    /// avoid round-tripping the payload through `JSONSerialization` again.
    fileprivate static func jsonRaw(_ inner: Data, key: String) -> Response {
        var out = Data()
        out.append(Data("{\"\(key)\":".utf8))
        out.append(inner)
        out.append(Data("}".utf8))
        return jsonData(out)
    }

    fileprivate static func jsonData(_ data: Data) -> Response {
        var response = Response(status: .ok, body: .init(byteBuffer: ByteBuffer(data: data)))
        response.headers[.contentType] = "application/json"
        return response
    }

    fileprivate static func jsonData(_ string: String) -> Response {
        jsonData(Data(string.utf8))
    }

    /// Build a binary response for an attachment: mimeType for
    /// `Content-Type`, friendly filename for `Content-Disposition`
    /// (so browsers download with the right name and CLI clients see
    /// it in `curl -OJ`).
    fileprivate static func attachmentResponse(data: Data, mimeType: String, filename: String) -> Response {
        var response = Response(status: .ok, body: .init(byteBuffer: ByteBuffer(data: data)))
        let contentType = mimeType.isEmpty ? "application/octet-stream" : mimeType
        response.headers[.contentType] = contentType
        if !filename.isEmpty, let dispositionName = HTTPField.Name("Content-Disposition") {
            // Sanitize quotes in the filename to keep the header valid.
            let safe = filename.replacingOccurrences(of: "\"", with: "")
            response.headers[dispositionName] = "inline; filename=\"\(safe)\""
        }
        return response
    }

    fileprivate static func intParam(_ req: Request, _ name: String, default fallback: Int) -> Int {
        guard let raw = req.uri.queryParameters[Substring(name)] else { return fallback }
        return Int(String(raw)) ?? fallback
    }

    // MARK: MCP adapters

    /// Hummingbird `Request` → MCP `HTTPRequest`. The SDK's transport
    /// reads `method`, `headers`, `body`, and `path` only — we don't
    /// have to translate the full URI.
    fileprivate static func makeMCPRequest(req: Request, body: Data) -> MCP.HTTPRequest {
        var headers: [String: String] = [:]
        for field in req.headers {
            // canonicalName is lowercased; MCP's `header(_:)` does
            // case-insensitive lookup so this is safe.
            headers[field.name.canonicalName] = field.value
        }
        return MCP.HTTPRequest(
            method: req.method.rawValue,
            headers: headers,
            body: body.isEmpty ? nil : body,
            path: "/mcp"
        )
    }

    /// MCP `HTTPResponse` → Hummingbird `Response`. Carries over the
    /// status code, all headers (including `Content-Type` and any
    /// `MCP-Session-Id` the transport sets), and the body bytes.
    fileprivate static func makeHummingbirdResponse(from mcpResponse: MCP.HTTPResponse) -> Response {
        var headers = HTTPFields()
        for (name, value) in mcpResponse.headers {
            if let fieldName = HTTPField.Name(name) {
                headers[fieldName] = value
            }
        }
        let body: ResponseBody
        if let data = mcpResponse.bodyData {
            body = .init(byteBuffer: ByteBuffer(data: data))
        } else {
            body = .init()
        }
        return Response(
            status: .init(code: mcpResponse.statusCode),
            headers: headers,
            body: body
        )
    }
}

/// Enforces `Authorization: Bearer <token>` when the user has configured a
/// token. Open by default for local development so first-launch UX isn't
/// blocked, but we surface a warning in the menu bar status.
struct BearerAuthMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let configured = AppConfigStore.shared.current.bearerToken
        if configured.isEmpty {
            return try await next(request, context)
        }
        guard
            let header = request.headers[.authorization],
            header == "Bearer \(configured)"
        else {
            throw HTTPError(.unauthorized)
        }
        return try await next(request, context)
    }
}
