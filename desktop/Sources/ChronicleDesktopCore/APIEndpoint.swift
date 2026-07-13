import Foundation

public enum ChronicleAPIEndpoint {
    /// Parse a Chronicle API base URL. Remote endpoints must use HTTPS because
    /// login passwords, refresh cookies, and bearer tokens cross this boundary.
    /// Plain HTTP is reserved for an API on this same machine during development.
    public static func validated(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), isAllowed(url) else { return nil }
        return url
    }

    public static func isAllowed(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty
        else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return isLoopbackHost(host)
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") ||
            host == "::1" || host == "0:0:0:0:0:0:0:1"
        {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let first = Int(octets[0]), first == 127,
              octets.allSatisfy({ part in
                  guard !part.isEmpty, let value = Int(part) else { return false }
                  return (0 ... 255).contains(value)
              })
        else { return false }
        return true
    }
}
