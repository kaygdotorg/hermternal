import HermternalCore
import Testing

@Test("registry resolves available and unknown capabilities as omitted")
func registryResolvesRuntimeState() throws {
    let search = CapabilityDescriptor(
        id: "search",
        name: "Search",
        purpose: "Find messages across saved transcripts.",
        state: .available,
        implementationSource: .builtIn
    )
    let registry = try CapabilityRegistry(capabilities: [search])

    #expect(registry.state(for: "search") == .available)
    #expect(registry.state(for: "missing") == .omitted)
}

@Test("omitted and unavailable states remain distinct and preserve reasons")
func omittedAndUnavailableStatesAreDistinct() throws {
    let registry = try CapabilityRegistry(capabilities: [
        CapabilityDescriptor(
            id: "omitted",
            name: "Omitted",
            purpose: "Not installed in this composition.",
            state: .omitted,
            implementationSource: .external
        ),
        CapabilityDescriptor(
            id: "unavailable",
            name: "Unavailable",
            purpose: "Needs a missing platform service.",
            state: .unavailable(reason: "The platform service is not installed."),
            implementationSource: .platformAdapter
        )
    ])

    #expect(registry.state(for: "omitted") == .omitted)
    #expect(
        registry.state(for: "unavailable")
            == .unavailable(reason: "The platform service is not installed.")
    )
    #expect(registry.capability(for: "unavailable")?.state.reason == "The platform service is not installed.")
}

@Test("registry order is stable regardless of adapter discovery order")
func registryUsesStableOrdering() throws {
    let descriptors = [
        CapabilityDescriptor(
            id: "voice",
            name: "Voice",
            purpose: "Voice controls.",
            state: .omitted,
            implementationSource: .platformAdapter
        ),
        CapabilityDescriptor(
            id: "search",
            name: "Search",
            purpose: "Transcript search.",
            state: .available,
            implementationSource: .builtIn
        ),
        CapabilityDescriptor(
            id: "actions",
            name: "Actions",
            purpose: "Action commands.",
            state: .omitted,
            implementationSource: .external
        )
    ]

    let first = try CapabilityRegistry(capabilities: descriptors)
    let second = try CapabilityRegistry(capabilities: descriptors.reversed())

    #expect(first.capabilities.map(\.id.rawValue) == ["actions", "search", "voice"])
    #expect(first.capabilities == second.capabilities)
}

@Test("Core modules cannot be registered as optional capabilities")
func coreModulesAreRejected() throws {
    var registry = CapabilityRegistry()
    let coreModule = CapabilityDescriptor(
        id: "history-cache",
        name: "History Cache",
        purpose: "Always-present transcript persistence.",
        state: .available,
        implementationSource: .builtIn,
        origin: .coreModule
    )

    do {
        try registry.register(coreModule)
        Issue.record("A Core module was accepted by the optional capability registry")
    } catch let error as CapabilityRegistrationError {
        #expect(error == .coreModule("history-cache"))
    } catch {
        Issue.record("Unexpected registration error: \(error)")
    }

    #expect(registry.capabilities.isEmpty)
}

@Test("batch registration does not partially apply after rejection")
func batchRegistrationIsAtomic() throws {
    var registry = CapabilityRegistry()
    let search = CapabilityDescriptor(
        id: "search",
        name: "Search",
        purpose: "Find messages across saved transcripts.",
        state: .available,
        implementationSource: .builtIn
    )
    let coreModule = CapabilityDescriptor(
        id: "history-cache",
        name: "History Cache",
        purpose: "Always-present transcript persistence.",
        state: .available,
        implementationSource: .builtIn,
        origin: .coreModule
    )

    do {
        try registry.register(contentsOf: [search, coreModule])
        Issue.record("A rejected batch was accepted")
    } catch let error as CapabilityRegistrationError {
        #expect(error == .coreModule("history-cache"))
    } catch {
        Issue.record("Unexpected registration error: \(error)")
    }

    #expect(registry.capabilities.isEmpty)
}
