import Foundation

/// Runs work on the next main-queue turn, outside Observation tracking.
///
/// `Task { }` inherits Observation's AccessList. A GCD hop does not. Use this
/// when an `@Observable` mutation's `onChange` must not re-register or read
/// more key paths on the same stack.
@MainActor
enum ObservationHop {
    static func enqueue(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(work)
        }
    }
}
