import Cocoa
import MCP

// iMessage Relay has two distinct process modes:
//
//   ImsgRelay            → menu bar app (default)
//   ImsgRelay --mcp      → MCP stdio server (no GUI, no Dock, no menu bar)
//
// The MCP mode is meant to be invoked by automation wrappers, e.g.:
//
//     #!/usr/bin/env bash
//     exec ssh -T mac '/Applications/iMessage Relay.app/Contents/MacOS/ImsgRelay --mcp'
//
// We branch as early as possible so we never even initialize AppKit in
// MCP mode — AppKit subtly steals stdin/stdout in ways the SDK won't
// like, and a clean stdio surface is non-negotiable for MCP.

let args = CommandLine.arguments
if args.contains("--mcp") {
    let queue: RelayQueue
    let imsg: ImsgClient
    do {
        queue = try RelayQueue()
        // We pass a no-op relay to ImsgClient because MCP mode doesn't
        // emit outbound events. The relay reference is `weak`, so a
        // dummy actor is the simplest way to satisfy the initializer.
        let tunnel = TunnelManager()
        let dummyRelay = HTTPRelay(queue: queue, tunnel: tunnel)
        imsg = try ImsgClient(queue: queue, relay: dummyRelay, tunnel: tunnel)
    } catch {
        FileHandle.standardError.write(Data("iMessage Relay --mcp failed to init: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

    // Run the MCP service on the main run loop via a Task. Stdio is
    // already line-oriented so we don't need NSApplication's event loop.
    let semaphore = DispatchSemaphore(value: 0)
    Task { @MainActor in
        do {
            let service = MCPService(imsg: imsg, transport: StdioTransport())
            try await service.run()
        } catch {
            FileHandle.standardError.write(Data("MCP server exited: \(error.localizedDescription)\n".utf8))
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
