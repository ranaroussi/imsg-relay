import Foundation

/// Runs the user's `archiveCommand` after a message has been written to the
/// local archive.
///
/// The contract is deliberately narrow: the command template comes from
/// Settings and is the only string the shell parses. The one substitution,
/// `{{to}}`, is the handle the message was addressed to, and it arrives as a
/// single quoted argument — so a handle containing shell metacharacters is an
/// argument, never code.
///
/// Everything else the script might want is passed as environment, not as
/// template variables: the script is told where the archive is rather than
/// having to reproduce this app's folder-naming rules.
enum ArchiveCommand {

    /// Wrap a value in single quotes for `zsh -c`, escaping embedded quotes.
    ///
    /// Inside single quotes the shell expands nothing, so this is the whole
    /// job: end the quoted run, emit an escaped quote, start a new run.
    /// `destination_caller_id` comes from the Messages database rather than
    /// from a sender, but quoting is cheap and the alternative is trusting a
    /// value we do not control the shape of.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Substitute `{{to}}` (tolerating inner whitespace) with a quoted handle.
    static func render(_ template: String, to recipient: String) -> String {
        let quoted = shellQuoted(recipient)
        var out = template
        for token in ["{{to}}", "{{ to }}", "{{to }}", "{{ to}}"] {
            out = out.replacingOccurrences(of: token, with: quoted)
        }
        return out
    }

    /// The handle passed as `{{to}}`. Raw, as Messages recorded it
    /// (`+447833222222`), not the filesystem-safe form used for folder names —
    /// scripts that need the folder get it from `IMSG_ARCHIVE_DIR`.
    ///
    /// Falls back to `unknown` so the value matches the archive's own
    /// fallback folder, and so the script never receives an empty argument it
    /// might mistake for a missing one.
    static func recipientArgument(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }
}

/// Serializes archive commands.
///
/// An actor rather than a detached task per message: a burst of a hundred
/// messages arriving at once (a group thread waking up, or a backfill after
/// the app was closed) would otherwise spawn a hundred shells at the same
/// time, and any two of them touching the same archive tree would race. One
/// at a time, in arrival order, is both safer and easier to reason about.
actor ArchiveCommandQueue {
    static let shared = ArchiveCommandQueue()

    /// A script that never exits would otherwise hold the queue forever and
    /// silently stop every later message from being processed.
    private static let timeout: TimeInterval = 120

    /// Cap on the output kept for the log. The command's stdout is not
    /// delivered anywhere, so this only bounds what we retain in memory.
    private static let outputCap = 64 * 1024

    func run(template: String, recipient: String?, rowID: Int64, folder: URL) async {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let handle = ArchiveCommand.recipientArgument(recipient)
        let command = ArchiveCommand.render(trimmed, to: handle)

        var env = ProcessInfo.processInfo.environment
        env["IMSG_TO"] = handle
        env["IMSG_ARCHIVE_DIR"] = folder.path
        env["IMSG_MESSAGE_ID"] = String(rowID)

        let started = Date()
        let result = await Self.execute(command: command, cwd: folder, env: env)
        let ms = Int(Date().timeIntervalSince(started) * 1000)

        let tail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.timedOut {
            Log.exec.error(
                "archive command for message \(rowID) timed out after \(Int(Self.timeout))s and was killed"
            )
        } else if result.exitCode != 0 {
            Log.exec.error(
                "archive command for message \(rowID) exited \(result.exitCode) in \(ms)ms: \(tail, privacy: .public)"
            )
        } else {
            Log.exec.info(
                "archive command for message \(rowID) ok in \(ms)ms: \(tail, privacy: .public)"
            )
        }
    }

    private struct Result {
        var exitCode: Int32
        var output: String
        var timedOut: Bool
    }

    /// Thread-safe accumulator for the child's output.
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data, cap: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard data.count < cap else { return }
            data.append(chunk.prefix(cap - data.count))
        }

        var string: String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private static func execute(command: String, cwd: URL, env: [String: String]) async -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // `-l` so the script sees the same PATH the user gets in a terminal:
        // a command that works when typed by hand should work here too.
        process.arguments = ["-lc", command]
        process.environment = env
        process.currentDirectoryURL = cwd
        // No stdin. A script that reads from it would otherwise block forever
        // on a pipe nobody is writing to.
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let buffer = Buffer()
        // Drain both pipes while the process runs. A child that writes more
        // than the pipe buffer holds blocks until someone reads, so waiting
        // for exit before reading deadlocks on exactly the chatty scripts
        // whose output is most worth having.
        for handle in [outPipe.fileHandleForReading, errPipe.fileHandleForReading] {
            handle.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty {
                    h.readabilityHandler = nil
                } else {
                    buffer.append(chunk, cap: outputCap)
                }
            }
        }

        do {
            try process.run()
        } catch {
            return Result(exitCode: -1, output: "failed to launch: \(error.localizedDescription)", timedOut: false)
        }

        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    process.terminationHandler = { _ in continuation.resume() }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard process.isRunning else { return false }
                // SIGTERM first so a well-behaved script can clean up, then
                // SIGKILL, because "asked politely" is not a guarantee.
                process.terminate()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return true
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        for handle in [outPipe.fileHandleForReading, errPipe.fileHandleForReading] {
            handle.readabilityHandler = nil
            if let rest = try? handle.readToEnd(), !rest.isEmpty {
                buffer.append(rest, cap: outputCap)
            }
        }

        return Result(
            exitCode: process.isRunning ? -1 : process.terminationStatus,
            output: buffer.string,
            timedOut: timedOut
        )
    }
}
