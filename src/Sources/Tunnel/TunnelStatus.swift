import Foundation
import Combine

/// Observable view of the Cloudflare tunnel state, decoupled from
/// `TunnelManager` so SwiftUI can subscribe without us having to make
/// the manager itself an `ObservableObject` (it lives outside the main
/// actor and is poked from background process pipes).
///
/// `TunnelManager` pushes updates here via a `Task { @MainActor in … }`
/// hop whenever it parses the cloudflared subprocess output or sees the
/// process terminate. Settings UI reads via `@ObservedObject`.
@MainActor
final class TunnelStatus: ObservableObject {
    static let shared = TunnelStatus()

    @Published var publicURL: String?
    @Published var isRunning: Bool = false

    private init() {}
}
