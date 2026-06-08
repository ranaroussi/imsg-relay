import Foundation
import AppKit

enum Permissions {
    /// Probe `~/Library/Messages/chat.db` to determine whether macOS
    /// has granted this binary Full Disk Access.
    ///
    /// We deliberately use `FileHandle(forReadingFrom:)` instead of
    /// `isReadableFile(atPath:)` — TCC denies metadata access on the
    /// Messages database in some versions of macOS, so the only way
    /// to be certain is to actually attempt to open the file.
    ///
    /// Returns:
    ///   - `true` if we can read chat.db (FDA granted), or if the file
    ///     simply doesn't exist (user never opened Messages — the
    ///     watcher will idle until they do).
    ///   - `false` if the file exists but we can't read it.
    static func hasFullDiskAccess() -> Bool {
        let path = ("~/Library/Messages/chat.db" as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)

        // If chat.db doesn't exist at all, treat as "no Messages
        // history yet" rather than "no permission". The watcher will
        // pick it up the moment the user signs into iMessage.
        if !FileManager.default.fileExists(atPath: path) {
            return true
        }

        guard let fh = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        try? fh.close()
        return true
    }

    /// Open System Settings → Privacy & Security → Full Disk Access.
    /// The legacy `preference.security` scheme is still handled by
    /// macOS 13+ System Settings and is the most reliable variant.
    static func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
