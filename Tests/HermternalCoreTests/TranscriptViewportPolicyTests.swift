import HermternalCore
import Testing

@Test("promotion preserves the resolved message identity")
func promotionPreservesResolvedTarget() throws {
    let identities = (1...6).map { MessageIdentity.server(ServerMessageID(rawValue: Int64($0))) }
    let boundedTail = Array(identities.dropFirst(2))
    let fullProjection = identities
    let anchor = TranscriptViewportTarget.message(id: identities[3])

    let boundedIndex = try #require(boundedTail.firstIndex(of: identities[3]))
    let promotedIndex = try #require(fullProjection.firstIndex(of: identities[3]))
    #expect(boundedIndex != promotedIndex)

    let beforePromotion = TranscriptViewportPolicy.resolveTarget(
        isStreaming: false,
        isNearBottom: false,
        routeChanged: false,
        currentTarget: anchor
    )
    let afterPromotion = TranscriptViewportPolicy.resolveTarget(
        isStreaming: false,
        isNearBottom: false,
        routeChanged: false,
        currentTarget: beforePromotion
    )

    #expect(afterPromotion == beforePromotion)
    #expect(afterPromotion == anchor)
}

@Test("viewport target precedence keeps explicit routes and Find ahead of bottom follow")
func viewportTargetPrecedence() {
    let explicit = MessageIdentity.server(ServerMessageID(rawValue: 7))
    let find = MessageIdentity.server(ServerMessageID(rawValue: 4))
    let older = MessageIdentity.server(ServerMessageID(rawValue: 2))

    #expect(
        TranscriptViewportPolicy.resolveTarget(
            explicitMessageID: explicit,
            findMessageID: find,
            isStreaming: true,
            isNearBottom: true,
            routeChanged: true
        ) == .message(id: explicit)
    )
    #expect(
        TranscriptViewportPolicy.resolveTarget(
            findMessageID: find,
            isStreaming: true,
            isNearBottom: true,
            routeChanged: true
        ) == .message(id: find)
    )
    #expect(
        TranscriptViewportPolicy.resolveTarget(
            isStreaming: true,
            isNearBottom: true,
            routeChanged: false,
            currentTarget: .message(id: older)
        ) == .bottom
    )
    #expect(
        TranscriptViewportPolicy.resolveTarget(
            isStreaming: true,
            isNearBottom: false,
            routeChanged: false,
            currentTarget: .message(id: older)
        ) == .message(id: older)
    )
    #expect(
        TranscriptViewportPolicy.resolveTarget(
            isStreaming: false,
            isNearBottom: false,
            routeChanged: true,
            currentTarget: .message(id: older)
        ) == .bottom
    )
}
