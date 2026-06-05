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
}
