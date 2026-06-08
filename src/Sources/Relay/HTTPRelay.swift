import Foundation

/// Drains `RelayQueue` to the configured remote endpoint, with retry/backoff
/// handled by the queue itself. Runs a single in-flight worker per relay
/// instance so we never out-of-order events for a given Mac.
actor HTTPRelay {
    private let queue: RelayQueue
    /// `nonisolated(unsafe)` because we let `relay(type:payload:)` build
    /// envelopes from any caller (synchronously) and we only ever read
    /// `publicURL` from it. `TunnelManager` is `@unchecked Sendable`, so
    /// the unsafe annotation is honest about what it actually is.
    nonisolated(unsafe) private weak var tunnel: TunnelManager?
    private var task: Task<Void, Never>?
    private var running = false

    init(queue: RelayQueue, tunnel: TunnelManager) {
        self.queue = queue
        self.tunnel = tunnel
    }

    func start() {
        guard !running else { return }
        running = true
        task = Task { [weak self] in
            await self?.loop()
        }
    }

    func stop() {
        running = false
        task?.cancel()
        task = nil
    }

    /// Build an envelope from a (type, payload) pair using the current
    /// config + tunnel URL, persist it, and let the loop drain.
    nonisolated func relay(type: EventType, payload: AnyCodable) {
        let config = AppConfigStore.shared.current
        let server = EventEnvelope.Server(
            identifier: config.serverIdentifier,
            endpoint: config.serverEndpoint,
            callback_url: tunnel?.publicURL ?? ""
        )
        let envelope = EventEnvelope(type: type, data: payload, server: server)
        do {
            try queue.enqueue(envelope)
        } catch {
            Log.relay.error("Failed to enqueue \(type.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loop() async {
        while !Task.isCancelled && running {
            // When the endpoint isn't configured yet, stand by entirely
            // — don't even peek at `dueEvents`. Earlier we marked these
            // events as failed, which burnt the retry counter and
            // shoveled them into the `dead` state within a few minutes
            // of running idle. Now they stay queued and drain the moment
            // the user fills in an endpoint.
            let config = AppConfigStore.shared.current
            if config.serverEndpoint.isEmpty {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                continue
            }

            do {
                let due = try queue.dueEvents(limit: 8)
                if due.isEmpty {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                    continue
                }
                for event in due {
                    if Task.isCancelled { return }
                    await deliver(event)
                }
            } catch {
                Log.relay.error("Queue read failed: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func deliver(_ event: RelayQueue.PendingEvent) async {
        let config = AppConfigStore.shared.current
        // Defensive: the outer loop already gates on `serverEndpoint`,
        // but a config change mid-batch could land us here without one.
        // Sleep briefly rather than torching the retry counter.
        guard let url = URL(string: config.serverEndpoint), !config.serverEndpoint.isEmpty else {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.bearerToken.isEmpty {
            req.setValue("Bearer \(config.bearerToken)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = event.envelopeJSON
        req.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                try markFailed(event)
                return
            }
            if (200..<300).contains(http.statusCode) {
                try queue.markDelivered(event.id)
            } else if (500..<600).contains(http.statusCode) || http.statusCode == 429 {
                // Retryable
                try markFailed(event)
            } else {
                // 4xx (other than 429) is a client error — log and park.
                Log.relay.error("Non-retryable status \(http.statusCode) — parking event \(event.id)")
                try queue.markFailed(event.id, attempts: AppConfigStore.shared.current.maxRetryAttempts, maxAttempts: AppConfigStore.shared.current.maxRetryAttempts)
            }
        } catch {
            Log.relay.error("POST failed: \(error.localizedDescription, privacy: .public)")
            try? markFailed(event)
        }
    }

    private func markFailed(_ event: RelayQueue.PendingEvent) throws {
        try queue.markFailed(
            event.id,
            attempts: event.attempts,
            maxAttempts: AppConfigStore.shared.current.maxRetryAttempts
        )
    }
}
