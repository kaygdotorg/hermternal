import HermternalCore
import Testing

@Test("runtime decoder preserves provider defaults and disabled reasoning")
func runtimeDecoderStates() {
    let unset = SessionRuntimeSnapshot.decode(.object([
        "model": .string("gpt"), "provider": .string("openai"),
        "reasoning_effort": .string(""), "running": .bool(true)
    ]))
    #expect(unset.model == "gpt")
    #expect(unset.provider == "openai")
    #expect(unset.reasoning == nil)
    #expect(unset.isRunning)

    let disabled = SessionRuntimeSnapshot.decode(.object([
        "info": .object(["reasoning_effort": .string("none"), "running": .bool(false)])
    ]))
    #expect(disabled.reasoning == .off)
    #expect(!disabled.isRunning)
    #expect(SessionRuntimeSnapshot.decode(nil) == SessionRuntimeSnapshot(model: nil, provider: nil, reasoning: nil, isRunning: false))
}

@Test("reasoning settings use gateway wire values")
func reasoningWireValues() {
    #expect(ReasoningSetting.off.wireValue == "none")
    #expect(ReasoningSetting.effort(.high).wireValue == "high")
    #expect(ReasoningEffort.allCases == [.minimal, .low, .medium, .high, .xhigh, .max, .ultra])
}

@Test("model inventory decoder reads provider rows and optional capabilities")
func modelInventoryDecoder() throws {
    let payload: JSONValue = .object([
        "providers": .array([
            .object([
                "slug": .string("openai"), "name": .string("OpenAI"), "is_current": .bool(true),
                "models": .array([.string("gpt-5"), .string("gpt-5-mini")]),
                "capabilities": .object([
                    "gpt-5": .object(["fast": .bool(true), "reasoning": .bool(true), "can_disable_reasoning": .bool(false)])
                ])
            ]),
            .object([
                "slug": .string("local"), "name": .string("Local"), "models": .array([])
            ])
        ])
    ])
    let inventory = try ModelInventory.decode(payload)
    #expect(inventory.providers.count == 2)
    #expect(inventory.providers[0].isCurrent)
    #expect(inventory.providers[0].models == ["gpt-5", "gpt-5-mini"])
    #expect(inventory.providers[0].capabilities["gpt-5"] == ModelCapabilities(
        supportsFast: true, supportsReasoning: true, canDisableReasoning: false
    ))
    #expect(inventory.providers[1].name == "Local")
}

@Test("model inventory decoder rejects malformed gateway shapes")
func modelInventoryMalformed() {
    #expect(throws: ModelInventoryDecodeError.missingProviders) {
        try ModelInventory.decode(.object(["providers": .string("bad")]))
    }
    #expect(throws: ModelInventoryDecodeError.malformedProvider) {
        try ModelInventory.decode(.object(["providers": .array([.object(["slug": .string("x")])])]))
    }
    do {
        try ModelInventory.decode(.object(["providers": .array([.object([
            "slug": .string("x"), "models": .array([]), "capabilities": .string("bad")
        ])])]))
        Issue.record("Expected malformed capabilities to throw")
    } catch let error as ModelInventoryDecodeError {
        #expect(error == .malformedCapabilities(slug: "x"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
