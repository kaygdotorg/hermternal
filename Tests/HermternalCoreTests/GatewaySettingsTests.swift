import Foundation
import HermternalCore
import Testing

@Test("provider discovery decodes advertised provider details")
func providerDiscoveryDecodesDetails() throws {
    let data = Data(
        #"{"providers":[{"name":"self-hosted","display_name":"Self-Hosted OIDC","supports_password":false}]}"#.utf8
    )

    let providers = try #require(
        AuthClient.decodeProviderResponse(data: data, statusCode: 200)
    )
    #expect(providers == [
        AuthProvider(
            name: "self-hosted",
            displayName: "Self-Hosted OIDC",
            supportsPassword: false
        )
    ])
}

@Test("missing or failed provider discovery is non-fatal")
func providerDiscoveryFailureIsUnknown() {
    #expect(
        AuthClient.decodeProviderResponse(
            data: Data(#"{"providers":[]}"#.utf8),
            statusCode: 404
        ) == nil
    )
    #expect(
        AuthClient.decodeProviderResponse(
            data: Data("not-json".utf8),
            statusCode: 200
        ) == nil
    )
}

@Test("available methods intersect client capability and gateway advertisement")
func availableMethodsIntersectCapabilities() {
    #expect(
        AuthMethod.available(
            clientSupported: [.browserPKCE],
            gatewayAdvertised: [.browserPKCE]
        ) == [.browserPKCE]
    )
    #expect(
        AuthMethod.available(
            clientSupported: [.browserPKCE],
            gatewayAdvertised: []
        ).isEmpty
    )
}

@Test("unsupported authentication method cannot be selected")
func unsupportedMethodCannotBeSelected() {
    #expect(
        AuthMethod.validatedSelection(.browserPKCE, from: []) == nil
    )
    #expect(
        AuthMethod.validatedSelection(.browserPKCE, from: [.browserPKCE]) == .browserPKCE
    )
}

@Test("authentication method persistence is scoped to each gateway")
func authenticationMethodPersistenceIsPerGateway() {
    let suiteName = "gateway-method-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = URL(string: "https://one.example")!
    let second = URL(string: "https://two.example")!
    AuthMethodStore.save(.browserPKCE, gateway: first, defaults: defaults)

    #expect(AuthMethodStore.load(gateway: first, defaults: defaults) == .browserPKCE)
    #expect(AuthMethodStore.load(gateway: second, defaults: defaults) == nil)

    AuthMethodStore.delete(gateway: first, defaults: defaults)
    #expect(AuthMethodStore.load(gateway: first, defaults: defaults) == nil)
}

@Test("gateway status exposes host and sanitizes advertised methods")
func gatewayStatusSnapshot() {
    let url = URL(string: "https://gateway.example/chat")!
    let status = GatewayStatus(
        url: url,
        connection: .ready,
        provider: nil,
        method: .browserPKCE,
        gatewayAdvertisedMethods: [.browserPKCE]
    )

    #expect(status.host == "gateway.example")
    #expect(status.availableMethods == [.browserPKCE])
    #expect(status.method == .browserPKCE)
}
