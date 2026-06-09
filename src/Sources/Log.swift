import Foundation
import os

enum Log {
    private static let subsystem = "com.imsg-relay.app"
    static let app     = Logger(subsystem: subsystem, category: "app")
    static let imsg    = Logger(subsystem: subsystem, category: "imsg")
    static let relay   = Logger(subsystem: subsystem, category: "relay")
    static let queue   = Logger(subsystem: subsystem, category: "queue")
    static let api     = Logger(subsystem: subsystem, category: "api")
    static let mcp     = Logger(subsystem: subsystem, category: "mcp")
    static let tunnel  = Logger(subsystem: subsystem, category: "tunnel")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let contacts = Logger(subsystem: subsystem, category: "contacts")
}
