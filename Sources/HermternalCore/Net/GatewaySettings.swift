import Foundation

/// An authentication provider advertised by a gateway.
public struct AuthProvider: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let displayName: String
    public let supportsPassword: Bool

    public var id: String { name }

    public init(name: String, displayName: String, supportsPassword: Bool) {
        self.name = name
        self.displayName = displayName
        self.supportsPassword = supportsPassword
    }

    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
        case supportsPassword = "supports_password"
    }
}

/// Authentication flows the client can perform.
///
/// Keep this enum limited to implemented flows. A future password-login
/// implementation adds a case here and then supplies it from discovery; it
/// does not create a second selection mechanism.
public enum AuthMethod: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
    case browserPKCE = "browser_pkce"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .browserPKCE: "Browser sign-in"
        }
    }

    /// The flows this composition can execute today.
    public static var clientSupported: [AuthMethod] { allCases }

    /// Intersects client capability with gateway advertisement while
    /// preserving the client's stable ordering.
    public static func available(
        clientSupported: [AuthMethod] = AuthMethod.clientSupported,
        gatewayAdvertised: [AuthMethod]
    ) -> [AuthMethod] {
        clientSupported.filter { gatewayAdvertised.contains($0) }
    }

    /// Returns a requested method only when it belongs to the computed
    /// capability intersection.
    public static func validatedSelection(
        _ requested: AuthMethod,
        from available: [AuthMethod]
    ) -> AuthMethod? {
        available.contains(requested) ? requested : nil
    }
}


/// Connection phase shown by Settings without exposing AppModel to the view.
public enum GatewayConnectionState: Equatable, Sendable {
    case signedOut
    case connecting
    case ready
    case failed(String)

    public var displayName: String {
        switch self {
        case .signedOut: "Signed out"
        case .connecting: "Connecting…"
        case .ready: "Connected"
        case .failed: "Connection failed"
        }
    }
}

/// Immutable gateway state rendered by Settings and reusable by other UI
/// adapters.
public struct GatewayStatus: Equatable, Sendable {
    public let url: URL
    public let host: String
    public let connection: GatewayConnectionState
    public let provider: AuthProvider?
    public let method: AuthMethod
    public let availableMethods: [AuthMethod]

    /// Builds a status from the gateway's advertised methods. Unsupported
    /// methods are removed before the snapshot is exposed, and the selected
    /// method is always one the client can actually perform.
    public init(
        url: URL,
        connection: GatewayConnectionState,
        provider: AuthProvider?,
        method: AuthMethod,
        gatewayAdvertisedMethods: [AuthMethod]
    ) {
        self.url = url
        self.host = url.host ?? "Unknown host"
        self.connection = connection
        self.provider = provider
        let available = AuthMethod.available(gatewayAdvertised: gatewayAdvertisedMethods)
        self.availableMethods = available
        self.method = available.contains(method) ? method : (available.first ?? method)
    }

    /// Convenience for callers that already computed the client/gateway
    /// intersection. The same validation still prevents an unsupported
    /// method from becoming selected.
    public init(
        url: URL,
        connection: GatewayConnectionState,
        provider: AuthProvider?,
        method: AuthMethod,
        availableMethods: [AuthMethod]
    ) {
        self.init(
            url: url,
            connection: connection,
            provider: provider,
            method: method,
            gatewayAdvertisedMethods: availableMethods
        )
    }
}

/// Persists the selected authentication flow independently for each gateway.
public enum AuthMethodStore {
    private static let keyPrefix = "gateway.auth-method."

    public static func load(gateway: URL, defaults: UserDefaults = .standard) -> AuthMethod? {
        guard let rawValue = defaults.string(forKey: key(gateway)) else { return nil }
        return AuthMethod(rawValue: rawValue)
    }

    public static func save(
        _ method: AuthMethod,
        gateway: URL,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(method.rawValue, forKey: key(gateway))
    }

    public static func delete(gateway: URL, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(gateway))
    }

    private static func key(_ gateway: URL) -> String {
        keyPrefix + gateway.absoluteString
    }
}
