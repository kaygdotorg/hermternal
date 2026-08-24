import Foundation

/// Tracks the latest submitted value until its work commits.
///
/// A caller submits a value when an interaction starts. Work checks or
/// consumes its ticket before it publishes. A newer submission invalidates all
/// older tickets without waiting for a timer or a debounce interval.
public struct SelectionCoalescer<Value: Equatable & Sendable>: Sendable {
    public struct Ticket: Equatable, Sendable {
        fileprivate let sequence: UInt64
        public let value: Value

        fileprivate init(sequence: UInt64, value: Value) {
            self.sequence = sequence
            self.value = value
        }
    }

    private var nextSequence: UInt64 = 0
    private var latestTicket: Ticket?

    public init() {}

    /// Submits a value and invalidates every earlier ticket.
    @discardableResult
    public mutating func submit(_ value: Value) -> Ticket {
        nextSequence &+= 1
        let ticket = Ticket(sequence: nextSequence, value: value)
        latestTicket = ticket
        return ticket
    }

    /// Returns true while the ticket remains the latest submission.
    public func isCurrent(_ ticket: Ticket) -> Bool {
        latestTicket == ticket
    }

    /// Consumes the latest ticket immediately before its publication.
    ///
    /// A stale ticket cannot consume or publish. Consumption makes a ticket
    /// single-use, so one settled selection has one publication opportunity.
    @discardableResult
    public mutating func consume(_ ticket: Ticket) -> Bool {
        guard latestTicket == ticket else { return false }
        latestTicket = nil
        return true
    }

    public var hasPendingSelection: Bool {
        latestTicket != nil
    }
}
