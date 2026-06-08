import Foundation
import Hummingbird

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
    private var task: Task<Void, Error>?

    init(port: Int, imsg: ImsgClient, tunnel: TunnelManager, queue: RelayQueue) {
        self.port = port
        self.imsg = imsg
        self.tunnel = tunnel
        self.queue = queue
    }

    func start() {
        let imsg = self.imsg
        let tunnel = self.tunnel
        let queue = self.queue
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

    fileprivate static func intParam(_ req: Request, _ name: String, default fallback: Int) -> Int {
        guard let raw = req.uri.queryParameters[Substring(name)] else { return fallback }
        return Int(String(raw)) ?? fallback
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
