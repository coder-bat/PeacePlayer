import Foundation

struct BackendIdentity: Equatable {
    let origin: URL
    let generation: UInt64

    func url(path: String) -> URL {
        origin.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    /// Server-relative URLs must remain attached to the server which returned them.
    func resolve(_ path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw BackendConfiguration.ConfigurationError.foreignOrigin
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let address = components.string,
              try BackendConfiguration.normalizedOrigin(address) == origin else {
            throw BackendConfiguration.ConfigurationError.foreignOrigin
        }
        return url
    }
}

/// Synchronous, thread-safe configuration for URLSession and background-download callers.
final class BackendConfiguration {
    static let defaultsKey = "peaceplayer.api_base_url"
    static let didChange = Notification.Name("peaceplayer.backendConfigurationDidChange")
    static let shared = BackendConfiguration()
    private let defaults: UserDefaults
    private let fallback: URL
    private let lock = NSLock()
    private var stored: BackendIdentity

    init(defaults: UserDefaults = .standard, fallback: URL? = nil) {
        self.defaults = defaults
        #if targetEnvironment(simulator)
        let defaultURL = URL(string: "http://localhost:8181")!
        #else
        // The backend moved off the development Mac to the homelab box
        // (batuniverse). Tailscale MagicDNS is preferred over the raw IP so a
        // tailnet address change does not require a new build. A Settings
        // override still wins over this fallback.
        let defaultURL = URL(string: "http://batuniverse:8181")
            ?? URL(string: "http://100.81.99.29:8181")!
        #endif
        self.fallback = fallback ?? defaultURL
        let configured = defaults.string(forKey: Self.defaultsKey)
        let origin = configured.flatMap { try? Self.normalizedOrigin($0) } ?? self.fallback
        self.stored = BackendIdentity(origin: origin, generation: 0)
    }

    var identity: BackendIdentity {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func isCurrent(_ identity: BackendIdentity) -> Bool { self.identity == identity }

    @discardableResult
    func update(_ input: String) throws -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = trimmed.isEmpty ? fallback : try Self.normalizedOrigin(trimmed)
        lock.lock()
        guard origin != stored.origin else { lock.unlock(); return false }
        stored = BackendIdentity(origin: origin, generation: stored.generation &+ 1)
        if trimmed.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) }
        else { defaults.set(origin.absoluteString, forKey: Self.defaultsKey) }
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return true
    }

    static func normalizedOrigin(_ input: String) throws -> URL {
        guard var c = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = c.host?.lowercased(), !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/", c.port.map({ (1...65535).contains($0) }) ?? true else {
            throw ConfigurationError.invalidURL
        }
        c.scheme = scheme
        c.host = host
        if c.port == (scheme == "https" ? 443 : 80) { c.port = nil }
        c.path = ""
        guard let url = c.url else { throw ConfigurationError.invalidURL }
        return url
    }

    enum ConfigurationError: LocalizedError {
        case invalidURL, foreignOrigin
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Enter a server address such as http://batuniverse:8181, without a path or password."
            case .foreignOrigin: return "The server returned an address for a different backend. Please retry."
            }
        }
    }
}
