import SwiftUI
import HermternalCore

#if DEBUG
/// Fixed sidebar data for local visual checks without a gateway.
///
/// The launch path is enabled only when `HERMTERNAL_FIXTURES` is exactly `1`.
/// Release builds do not compile the environment-controlled fixture path.
enum SidebarFixtures {
    static let isEnabled = ProcessInfo.processInfo.environment["HERMTERNAL_FIXTURES"] == "1"
    /// Fixture authority is deliberately non-production so labels and copied
    /// links never claim the real gateway.
    static let gatewayURL = URL(string: "https://fixtures.hermternal.invalid")!

    /// The complete fixture set is built once per process.
    static let sessions: [ChatSession] = {
        let now = Date()
        return [
            session(
                id: "fixture-pinned",
                title: "Pinned release notes",
                preview: "Review the release notes before the afternoon deploy.",
                startedAt: now.addingTimeInterval(-1_800),
                lastActive: now.addingTimeInterval(-300),
                pinned: true,
                messageCount: 8
            ),
            session(
                id: "fixture-transcript",
                title: "Long transcript positioning",
                preview: "Fixture message 1199 is the newest message.",
                startedAt: now.addingTimeInterval(-600),
                lastActive: now.addingTimeInterval(-60),
                messageCount: 200
            ),
            session(
                id: "fixture-cron-daily",
                title: "Daily stand-up digest",
                preview: "The scheduled digest is ready.",
                startedAt: now.addingTimeInterval(-7_200),
                lastActive: now.addingTimeInterval(-3_600),
                source: "cron",
                messageCount: 1
            ),
            session(
                id: "fixture-cron-weekly",
                title: "Weekly repository summary",
                preview: "The scheduled repository summary is ready.",
                startedAt: now.addingTimeInterval(-3 * 86_400),
                lastActive: now.addingTimeInterval(-3 * 86_400),
                source: "cron",
                messageCount: 2
            ),
            session(
                id: "fixture-cron-monthly",
                title: "Monthly dependency report",
                preview: "The scheduled dependency report is ready.",
                startedAt: now.addingTimeInterval(-18 * 86_400),
                lastActive: now.addingTimeInterval(-18 * 86_400),
                source: "cron",
                messageCount: 3
            ),
            session(
                id: "fixture-cron-nightly",
                title: "Nightly test report",
                preview: "The nightly scheduled test report is ready.",
                startedAt: now.addingTimeInterval(-10_800),
                lastActive: now.addingTimeInterval(-9_000),
                source: "cron",
                messageCount: 4
            ),
            session(
                id: "fixture-cron-release",
                title: "Release readiness digest",
                preview: "The scheduled release readiness digest is ready.",
                startedAt: now.addingTimeInterval(-4 * 86_400),
                lastActive: now.addingTimeInterval(-4 * 86_400),
                source: "cron",
                messageCount: 5
            ),
            session(
                id: "fixture-today",
                title: "Today’s design review",
                preview: "We agreed on the final sidebar spacing.",
                startedAt: now.addingTimeInterval(-14_400),
                lastActive: now.addingTimeInterval(-7_200),
                messageCount: 12
            ),
            session(
                id: "fixture-yesterday",
                title: "Yesterday’s deployment",
                preview: "The deployment completed without errors.",
                startedAt: now.addingTimeInterval(-86_400 - 7_200),
                lastActive: now.addingTimeInterval(-86_400 - 3_600),
                messageCount: 6
            ),
            session(
                id: "fixture-week",
                title: "Last seven days planning",
                preview: "Planning notes from earlier this week.",
                startedAt: now.addingTimeInterval(-4 * 86_400),
                lastActive: now.addingTimeInterval(-4 * 86_400),
                messageCount: 5
            ),
            session(
                id: "fixture-month",
                title: "Last thirty days metrics",
                preview: "A review of the latest metrics.",
                startedAt: now.addingTimeInterval(-12 * 86_400),
                lastActive: now.addingTimeInterval(-12 * 86_400),
                messageCount: 4
            ),
            session(
                id: "fixture-older",
                title: "Older architecture notes",
                preview: "An older conversation retained for context.",
                startedAt: now.addingTimeInterval(-75 * 86_400),
                lastActive: now.addingTimeInterval(-75 * 86_400),
                messageCount: 9
            ),
            session(
                id: "fixture-no-last-active",
                title: "No activity timestamp",
                preview: "This row has no last-active value.",
                startedAt: now.addingTimeInterval(-2 * 86_400),
                lastActive: nil,
                messageCount: 0
            ),
            session(
                id: "fixture-derived-title",
                title: "",
                preview: "A title derived from the preview text",
                startedAt: now.addingTimeInterval(-5_400),
                lastActive: now.addingTimeInterval(-2_700),
                messageCount: 2
            ),
            session(
                id: "fixture-new-chat",
                title: "",
                preview: "### Task: inspect the generated changelog",
                startedAt: now.addingTimeInterval(-6 * 86_400),
                lastActive: now.addingTimeInterval(-6 * 86_400),
                messageCount: 1
            ),
            session(
                id: "fixture-long-title",
                title: "A deliberately long conversation title that must truncate in the narrow native sidebar column",
                preview: "The title above exercises native one-line truncation.",
                startedAt: now.addingTimeInterval(-9 * 86_400),
                lastActive: now.addingTimeInterval(-9 * 86_400),
                messageCount: 7
            ),
            session(
                id: "fixture-archived",
                title: "Archived customer research",
                preview: "This completed conversation remains archived.",
                startedAt: now.addingTimeInterval(-45 * 86_400),
                lastActive: now.addingTimeInterval(-45 * 86_400),
                archived: true,
                messageCount: 11
            )
        ]
    }()

    static let transcriptSessionID = "fixture-transcript"

    static let transcriptMessages: [ChatMessage] = (0..<200).map { offset in
        let rawID = Int64(1_000 + offset)
        let role: Role = offset.isMultiple(of: 2) ? .user : .assistant
        return ChatMessage(
            id: .server(ServerMessageID(rawValue: rawID)),
            role: role,
            text: "Fixture transcript message \(rawID): numbered content for positioning.",
            timestamp: Date(timeIntervalSince1970: TimeInterval(rawID))
        )
    }

    static let transcriptSource: any TranscriptSource = FixtureTranscriptSource(
        sessionID: transcriptSessionID,
        messages: transcriptMessages
    )

    private struct FixtureTranscriptSource: TranscriptSource, Sendable {
        let sessionID: String
        let rows: [JSONValue]

        init(sessionID: String, messages: [ChatMessage]) {
            self.sessionID = sessionID
            self.rows = messages.map { message in
                let rawID: Int64
                if case .server(let serverID) = message.id {
                    rawID = serverID.rawValue
                } else {
                    rawID = 0
                }
                return .object([
                    "id": .integer(rawID),
                    "role": .string(message.role.rawValue),
                    "text": .string(message.text),
                    "timestamp": .number(message.timestamp?.timeIntervalSince1970 ?? 0)
                ])
            }
        }

        func fetchAuthoritative(sessionID: String) async throws -> AuthoritativeTranscript {
            guard sessionID == self.sessionID else {
                return AuthoritativeTranscript(rows: [], serverTotal: 0)
            }
            return AuthoritativeTranscript(rows: rows, serverTotal: rows.count)
        }

        func resume(sessionID: String) async throws -> ResumedTranscript {
            ResumedTranscript(
                liveSessionID: sessionID == self.sessionID ? "fixture-live-session" : nil,
                rows: [],
                messageCount: sessionID == self.sessionID ? rows.count : 0
            )
        }
    }

    @MainActor
    static func previewModel() -> AppModel {
        let model = AppModel()
        model.serverText = gatewayURL.absoluteString
        model.sessions = sessions
        model.phase = .ready
        return model
    }

    private static func session(
        id: String,
        title: String,
        preview: String,
        startedAt: Date,
        lastActive: Date?,
        pinned: Bool = false,
        archived: Bool = false,
        source: String = "chat",
        messageCount: Int = 0
    ) -> ChatSession {
        ChatSession(from: .object([
            "id": .string(id),
            "title": .string(title),
            "preview": .string(preview),
            "started_at": .number(startedAt.timeIntervalSince1970),
            "last_active": lastActive.map { .number($0.timeIntervalSince1970) } ?? .null,
            "pinned": .bool(pinned),
            "archived": .bool(archived),
            "source": .string(source),
            "profile": .string("fixture"),
            "message_count": .integer(Int64(messageCount))
        ]))
    }
}
#else
enum SidebarFixtures {
    static let isEnabled = false
}
#endif

#if DEBUG
#Preview("Sidebar — fixtures") {
    SidebarView(
        model: SidebarFixtures.previewModel(),
        accountName: "Fixture account",
        accountDetail: "No gateway connection",
        accountID: "fixture-account"
    )
    .frame(width: 280, height: 720)
}
#endif
