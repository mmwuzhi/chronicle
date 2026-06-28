import Foundation

public enum ChronicleDesktopPaths {
    public static func defaultQueueURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["CHRONICLE_DESKTOP_QUEUE_PATH"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appending(path: "Chronicle")
            .appending(path: "quick-capture-queue.json")
    }

    public static func defaultLocalDatabaseURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["CHRONICLE_DESKTOP_DB_PATH"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appending(path: "Chronicle")
            .appending(path: "chronicle-local.sqlite3")
    }

    // Where pinned desktop stickies persist (id + cached content + window frame), so
    // they restore across launches and render offline. See PinnedStickyController.
    public static func defaultPinsURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["CHRONICLE_DESKTOP_PINS_PATH"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appending(path: "Chronicle")
            .appending(path: "pinned-captures.json")
    }
}
