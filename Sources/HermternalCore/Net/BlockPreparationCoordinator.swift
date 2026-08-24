import Foundation

/// Coordinates background preparation of transcript blocks without knowing how a
/// renderer represents prepared content.
///
/// `Prepared` is intentionally opaque to HermternalCore. A phase-two renderer
/// supplies the preparation closure, which should return an immutable
/// `Sendable` value suitable for its platform. The coordinator never creates
/// or touches AppKit layout managers or view types.
public final class BlockPreparationCoordinator: @unchecked Sendable {
    /// The maximum number of preparation closures that may be active at once.
    public let laneCount: Int

    private let lanes: BoundedPrefetchCoordinator
    private let state = State()

    public init(laneCount: Int = 4) {
        let boundedLaneCount = min(4, max(1, laneCount))
        self.laneCount = boundedLaneCount
        self.lanes = BoundedPrefetchCoordinator(limit: boundedLaneCount)
    }

    /// Cancels the current request.
    ///
    /// Queued blocks are rejected before the preparation closure is entered.
    /// In-flight preparation is also cancelled when its task cooperates with
    /// Swift concurrency cancellation; a result that completes after this call
    /// is never delivered.
    public func cancel() {
        state.cancelCurrent()
    }

    /// Prepares blocks in bounded lanes and delivers each result independently.
    ///
    /// Starting a new request supersedes and cancels the previous request. The
    /// closure is checked for cancellation immediately before it is entered,
    /// which keeps queued work from starting expensive shaping after a route or
    /// viewport change. Errors and cancelled preparations are omitted. Results
    /// are delivered as soon as each lane completes; no request-sized result
    /// array is retained by this coordinator.
    ///
    /// The coordinator itself is platform-neutral and does not hop to the main
    /// actor. A caller that updates SwiftUI/AppKit state must make `onResult`
    /// call `MainActor.run` (or otherwise isolate that state to `@MainActor`).
    /// Apple's Core Text Programming Guide describes its layout objects as
    /// thread-safe for non-mutating use
    /// (https://developer.apple.com/library/archive/documentation/StringsTextFonts/Conceptual/CoreText_Programming/); `NSLayoutManager` and
    /// `NSTextLayoutManager` are not thread-safe and must be created and used
    /// on the main actor.
    public func prepare<Prepared: Sendable>(
        _ blocks: [TranscriptBlock],
        preparation: @escaping @Sendable (TranscriptBlock) async throws -> Prepared?,
        onResult: @escaping @Sendable (Prepared) async -> Void
    ) async {
        let request = state.beginRequest()
        guard !Task.isCancelled, !blocks.isEmpty else {
            request.cancel()
            state.finish(request)
            return
        }
        let lanes = self.lanes
        let task = Task { [lanes] in
            await lanes.prefetch(
                blocks,
                operation: { (block: TranscriptBlock) async throws -> Prepared? in
                    guard !Task.isCancelled, !request.isCancelled else { return nil }
                    do {
                        let prepared = try await preparation(block)
                        guard !Task.isCancelled, !request.isCancelled else { return nil }
                        return prepared
                    } catch {
                        return nil
                    }
                },
                onResult: { (prepared: Prepared) async -> Void in
                    guard !Task.isCancelled, !request.isCancelled else { return }
                    await onResult(prepared)
                }
            )
        }
        request.install(task)
        await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            request.cancelTask()
        })
        state.finish(request)
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Request?

        func beginRequest() -> Request {
            let request = Request()
            lock.lock()
            current?.cancel()
            current = request
            lock.unlock()
            return request
        }

        func cancelCurrent() {
            lock.lock()
            current?.cancel()
            current = nil
            lock.unlock()
        }

        func finish(_ request: Request) {
            lock.lock()
            if current === request {
                current = nil
            }
            lock.unlock()
        }
    }

    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var task: Task<Void, Never>?

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func install(_ task: Task<Void, Never>) {
            lock.lock()
            if cancelled {
                lock.unlock()
                task.cancel()
            } else {
                self.task = task
                lock.unlock()
            }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            self.task = nil
            lock.unlock()
            task?.cancel()
        }

        func cancelTask() {
            lock.lock()
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }
}
