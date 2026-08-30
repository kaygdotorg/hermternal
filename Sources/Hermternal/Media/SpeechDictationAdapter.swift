import HermternalCore
import AVFoundation
import Foundation
import Speech
import os.lock

/// Errors from the on-device speech adapter.
public enum SpeechDictationAdapterError: LocalizedError, Sendable {
    case microphonePermissionDenied
    case unsupportedAudioFormat
    case notPrepared
    case captureStartFailed(String)
    case inputOverloaded
    case convertedBufferPoolExhausted
    case speechFailed(String)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is required for dictation."
        case .unsupportedAudioFormat:
            return "The microphone format is not supported for on-device dictation."
        case .notPrepared:
            return "Dictation is not prepared."
        case .captureStartFailed(let reason):
            return "Dictation could not start: \(reason)"
        case .inputOverloaded:
            return "Dictation stopped: microphone input exceeded its bounded 64-buffer pool."
        case .convertedBufferPoolExhausted:
            return "Dictation stopped: converted audio exceeded its bounded 64-buffer pool."
        case .speechFailed(let reason):
            return "On-device dictation failed: \(reason)"
        }
    }
}

/// Captures microphone input and feeds SpeechAnalyzer without retaining audio data.
///
/// The input and converted rings are bounded. The tap only copies into an
/// already allocated input slot; conversion and AnalyzerInput construction run
/// on the analysis task, never on the real-time callback.
private final class SpeechSampleClock: @unchecked Sendable {
    var nextSampleTime: AVAudioFramePosition = 0
}
private final class ConverterInputState: @unchecked Sendable {
    private let lock = NSLock()
    private var supplied = false

    func reset() {
        lock.lock()
        supplied = false
        lock.unlock()
    }

    func supply(_ inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !supplied else {
            inputStatus.pointee = .noDataNow
            return false
        }
        supplied = true
        inputStatus.pointee = .haveData
        return true
    }
}

private struct SpeechSourceBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
private final class SpeechSignalBox: @unchecked Sendable {
    var continuation: AsyncStream<Void>.Continuation!
}


private final class SpeechInputPool: @unchecked Sendable {
    fileprivate final class Slot: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    private final class State: @unchecked Sendable {
        var free: [Slot]
        var ready: [Slot?]
        var readyHead = 0
        var readyCount = 0
        var closed = false

        init(format: AVAudioFormat, capacity: Int, frameCapacity: AVAudioFrameCount) {
            free = (0..<capacity).compactMap { _ in
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: frameCapacity
                ) else {
                    return nil
                }
                return Slot(buffer)
            }
            ready = Array(repeating: nil, count: capacity)
        }
    }

    private let capacity: Int
    private let lock: OSAllocatedUnfairLock<State>

    init(format: AVAudioFormat, capacity: Int, frameCapacity: AVAudioFrameCount) {
        self.capacity = capacity
        lock = OSAllocatedUnfairLock(
            initialState: State(format: format, capacity: capacity, frameCapacity: frameCapacity)
        )
    }

    /// Never waits in the audio tap. A busy lock is terminal overload rather
    /// than an unreported loss of microphone samples.
    func enqueue(_ source: AVAudioPCMBuffer) -> Bool {
        let sourceBox = SpeechSourceBox(source)
        return lock.withLockIfAvailable { state in
            guard !state.closed, let slot = state.free.popLast() else {
                return false
            }
            copy(sourceBox.buffer, into: slot.buffer)
            state.ready[(state.readyHead + state.readyCount) % capacity] = slot
            state.readyCount += 1
            return true
        } ?? false
    }

    func dequeue() -> Slot? {
        lock.withLock { state in
            guard state.readyCount > 0, let slot = state.ready[state.readyHead] else {
                return nil
            }
            state.ready[state.readyHead] = nil
            state.readyHead = (state.readyHead + 1) % capacity
            state.readyCount -= 1
            return slot
        }
    }

    func release(_ slot: Slot) {
        lock.withLock { state in
            state.free.append(slot)
        }
    }

    func close() {
        lock.withLock { $0.closed = true }
    }

    func isClosedAndEmpty() -> Bool {
        lock.withLock { $0.closed && $0.readyCount == 0 }
    }

    private func copy(_ source: AVAudioPCMBuffer, into destination: AVAudioPCMBuffer) {
        destination.frameLength = min(source.frameLength, destination.frameCapacity)
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source.audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        let bytesPerFrame = max(
            1,
            Int(destination.format.streamDescription.pointee.mBytesPerFrame)
        )
        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            let sourceBuffer = sourceBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffers[index].mData else {
                continue
            }
            let destinationCapacity = bytesPerFrame * Int(destination.frameCapacity)
            let byteCount = min(sourceBuffer.mDataByteSize, UInt32(destinationCapacity))
            memcpy(destinationData, sourceData, Int(byteCount))
            destinationBuffers[index].mDataByteSize = byteCount
        }
    }
}

/// Converted slots are consumed by SpeechAnalyzer and are deliberately not
/// reused during a run: every AnalyzerInput retains a distinct buffer until
/// the analyzer has consumed it. The ring is recycled by the next run.
private final class SpeechConvertedBufferPool: @unchecked Sendable {
    final class Slot: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let inputState = ConverterInputState()

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    private var slots: [Slot]
    private var nextIndex = 0

    init(format: AVAudioFormat, capacity: Int, frameCapacity: AVAudioFrameCount) {
        slots = (0..<capacity).compactMap { _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
                return nil
            }
            return Slot(buffer: buffer)
        }
    }

    func take() -> Slot? {
        guard nextIndex < slots.count else { return nil }
        let slot = slots[nextIndex]
        nextIndex += 1
        slot.inputState.reset()
        return slot
    }
}

@available(macOS 26.0, iOS 26.0, *)
public final class SpeechDictationAdapter: SpeechDictating, @unchecked Sendable {
    private static let inputBufferSize: AVAudioFrameCount = 1_024
    private static let inputQueueCapacity = 64
    private static let convertedBufferCapacity = 64

    private let locale: Locale
    private let lock = NSLock()
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var engine: AVAudioEngine?
    private var inputContinuation: AsyncThrowingStream<AnalyzerInput, any Error>.Continuation?
    private var inputPool: SpeechInputPool?
    private var convertedPool: SpeechConvertedBufferPool?
    private var inputSignal: AsyncStream<Void>.Continuation?
    private var runTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var isRunning = false

    public init(locale: Locale = .current) {
        self.locale = locale
    }
    deinit {
        shutdownSynchronously()
    }


    public func availability() async -> DictationAvailability {
        guard SpeechTranscriber.isAvailable else {
            return .unavailable(reason: "On-device speech transcription is unavailable on this device.")
        }

        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return .unsupportedLocale(locale.identifier)
        }

        if AVAudioApplication.shared.recordPermission == .denied {
            return .permissionDenied
        }

        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier == supportedLocale.identifier }) else {
            return .needsModelInstall(locale: supportedLocale.identifier)
        }
        return .available
    }

    public func prepare() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechDictationAdapterError.speechFailed("SpeechTranscriber is unavailable.")
        }
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechDictationAdapterError.speechFailed("Locale \(locale.identifier) is not supported.")
        }

        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            preset: .progressiveTranscription
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        lock.withLock {
            self.transcriber = transcriber
        }
    }

    public func start() async throws -> AsyncThrowingStream<DictationUpdate, any Error> {
        try Task.checkCancellation()
        guard await availability() != .permissionDenied else {
            throw SpeechDictationAdapterError.microphonePermissionDenied
        }
        try await prepare()
        guard let transcriber = lockedTranscriber() else {
            throw SpeechDictationAdapterError.notPrepared
        }

        let permission = await requestPermission()
        guard permission else {
            throw SpeechDictationAdapterError.microphonePermissionDenied
        }

        await cancelCurrentRun()

        let modules: [any SpeechModule] = [transcriber]
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw SpeechDictationAdapterError.unsupportedAudioFormat
        }
        let inputStream = AsyncThrowingStream<AnalyzerInput, any Error>(
            bufferingPolicy: .bufferingOldest(Self.inputQueueCapacity)
        ) { [weak self] (continuation: AsyncThrowingStream<AnalyzerInput, any Error>.Continuation) in
            self?.lock.lock()
            self?.inputContinuation = continuation
            self?.lock.unlock()
        }
        guard let inputContinuation = lockedInputContinuation() else {
            throw SpeechDictationAdapterError.notPrepared
        }
        let updates = AsyncThrowingStream<DictationUpdate, any Error>(
            bufferingPolicy: .bufferingNewest(Self.inputQueueCapacity)
        ) { [weak self] (continuation: AsyncThrowingStream<DictationUpdate, any Error>.Continuation) in
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                Task { await self.cancel() }
            }
            self?.startCapture(
                transcriber: transcriber,
                analyzerFormat: analyzerFormat,
                inputStream: inputStream,
                inputContinuation: inputContinuation,
                updates: continuation
            )
        }
        return updates
    }

    public func stop() async {
        let state = takeRunState()
        state.engine?.inputNode.removeTap(onBus: 0)
        state.engine?.stop()
        state.inputPool?.close()
        state.inputSignal?.finish()
        state.continuation?.finish()
        _ = await state.task?.value
        if let analyzer = state.analyzer {
            await analyzer.cancelAndFinishNow()
        }
        deactivateAudioSession()
    }

    public func cancel() async {
        let state = takeRunState()
        state.engine?.inputNode.removeTap(onBus: 0)
        state.engine?.stop()
        state.inputPool?.close()
        state.inputSignal?.finish()
        state.continuation?.finish(throwing: CancellationError())
        if let analyzer = state.analyzer {
            await analyzer.cancelAndFinishNow()
        }
        state.task?.cancel()
        _ = await state.task?.value
        deactivateAudioSession()
    }

    private func startCapture(
        transcriber: SpeechTranscriber,
        analyzerFormat: AVAudioFormat,
        inputStream: AsyncThrowingStream<AnalyzerInput, any Error>,
        inputContinuation: AsyncThrowingStream<AnalyzerInput, any Error>.Continuation,
        updates: AsyncThrowingStream<DictationUpdate, any Error>.Continuation
    ) {
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true)
            #endif

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let sourceFormat = inputNode.outputFormat(forBus: 0)
            guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
                throw SpeechDictationAdapterError.unsupportedAudioFormat
            }
            guard let converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat) else {
                throw SpeechDictationAdapterError.unsupportedAudioFormat
            }
            let inputPool = SpeechInputPool(
                format: sourceFormat,
                capacity: Self.inputQueueCapacity,
                frameCapacity: Self.inputBufferSize
            )
            let convertedPool = SpeechConvertedBufferPool(
                format: analyzerFormat,
                capacity: Self.convertedBufferCapacity,
                frameCapacity: convertedCapacity(
                    sourceFormat: sourceFormat,
                    targetFormat: analyzerFormat
                )
            )
            let signalBox = SpeechSignalBox()
            let inputSignals = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) {
                continuation in
                signalBox.continuation = continuation
            }
            let inputSignal = signalBox.continuation
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let clock = SpeechSampleClock()

            inputNode.installTap(onBus: 0, bufferSize: Self.inputBufferSize, format: sourceFormat) {
                [signalBox] buffer, _ in
                guard inputPool.enqueue(buffer) else {
                    inputPool.close()
                    inputContinuation.finish(throwing: SpeechDictationAdapterError.inputOverloaded)
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                    #if os(iOS)
                    try? AVAudioSession.sharedInstance().setActive(
                        false,
                        options: .notifyOthersOnDeactivation
                    )
                    #endif
                    signalBox.continuation.yield(())
                    return
                }
                signalBox.continuation.yield(())
            }

            lock.withLock {
                self.engine = engine
                self.analyzer = analyzer
                self.converter = converter
                self.inputPool = inputPool
                self.convertedPool = convertedPool
                self.inputSignal = inputSignal
                self.inputContinuation = inputContinuation
                self.isRunning = true
            }

            do {
                try engine.start()
            } catch {
                let failure = SpeechDictationAdapterError.captureStartFailed("Audio engine unavailable.")
                let failedState = takeRunState()
                failedState.engine?.inputNode.removeTap(onBus: 0)
                failedState.engine?.stop()
                failedState.inputPool?.close()
                failedState.inputSignal?.finish()
                failedState.continuation?.finish(throwing: failure)
                deactivateAudioSession()
                throw failure
            }

            let task = Task { [weak self, analyzer] in
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for await _ in inputSignals {
                                while let slot = inputPool.dequeue() {
                                    guard let outputSlot = convertedPool.take() else {
                                        inputPool.release(slot)
                                        inputPool.close()
                                        inputContinuation.finish(
                                            throwing: SpeechDictationAdapterError.convertedBufferPoolExhausted
                                        )
                                        self?.stopEngineOnly()
                                        break
                                    }
                                    defer { inputPool.release(slot) }
                                    let output = outputSlot.buffer
                                    output.frameLength = 0
                                    var conversionError: NSError?
                                    let status = converter.convert(to: output, error: &conversionError) {
                                        _, inputStatus in
                                        guard outputSlot.inputState.supply(inputStatus) else {
                                            return nil
                                        }
                                        return slot.buffer
                                    }
                                    guard status == .haveData,
                                          conversionError == nil,
                                          output.frameLength > 0 else {
                                        inputPool.close()
                                        inputContinuation.finish(
                                            throwing: SpeechDictationAdapterError.speechFailed(
                                                conversionError == nil
                                                    ? "Audio conversion returned no data."
                                                    : "Audio conversion failed."
                                            )
                                        )
                                        self?.stopEngineOnly()
                                        break
                                    }

                                    // The clock follows converted frames, so its time scale
                                    // matches AnalyzerInput even when hardware and analyzer
                                    // rates differ.
                                    let timeScale = max(1, Int32(analyzerFormat.sampleRate))
                                    let startTime = CMTime(
                                        value: clock.nextSampleTime,
                                        timescale: timeScale
                                    )
                                    clock.nextSampleTime += AVAudioFramePosition(output.frameLength)
                                    let input = AnalyzerInput(
                                        buffer: output,
                                        bufferStartTime: startTime
                                    )
                                    switch inputContinuation.yield(input) {
                                    case .enqueued(_):
                                        break
                                    case .dropped(_):
                                        inputPool.close()
                                        inputContinuation.finish(
                                            throwing: SpeechDictationAdapterError.convertedBufferPoolExhausted
                                        )
                                        self?.stopEngineOnly()
                                    case .terminated:
                                        inputPool.close()
                                    @unknown default:
                                        inputPool.close()
                                        inputContinuation.finish(
                                            throwing: SpeechDictationAdapterError.convertedBufferPoolExhausted
                                        )
                                        self?.stopEngineOnly()
                                    }
                                }
                                if inputPool.isClosedAndEmpty() {
                                    inputContinuation.finish()
                                    return
                                }
                            }
                        }
                        group.addTask {
                            let lastTime = try await analyzer.analyzeSequence(inputStream)
                            if let lastTime {
                                try await analyzer.finalizeAndFinish(through: lastTime)
                            } else {
                                try await analyzer.finalizeAndFinishThroughEndOfInput()
                            }
                        }
                        group.addTask {
                            for try await result in transcriber.results {
                                updates.yield(
                                    DictationUpdate(
                                        text: String(result.text.characters),
                                        isFinal: result.isFinal
                                    )
                                )
                            }
                        }
                        try await group.waitForAll()
                    }
                    updates.finish()
                } catch is CancellationError {
                    updates.finish(throwing: CancellationError())
                } catch {
                    updates.finish(
                        throwing: SpeechDictationAdapterError.speechFailed(
                            "Speech processing failed."
                        )
                    )
                }
                self?.shutdownCapture()
            }

            lock.withLock {
                self.runTask = task
            }
        } catch {
            deactivateAudioSession()
            updates.finish(throwing: error)
        }
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func lockedTranscriber() -> SpeechTranscriber? {
        lock.withLock { transcriber }
    }

    private func lockedInputContinuation() -> AsyncThrowingStream<AnalyzerInput, any Error>.Continuation? {
        lock.withLock { inputContinuation }
    }

    private func takeRunState() -> (
        engine: AVAudioEngine?,
        continuation: AsyncThrowingStream<AnalyzerInput, any Error>.Continuation?,
        task: Task<Void, Never>?,
        analyzer: SpeechAnalyzer?,
        inputPool: SpeechInputPool?,
        convertedPool: SpeechConvertedBufferPool?,
        inputSignal: AsyncStream<Void>.Continuation?
    ) {
        lock.withLock {
            let state = (
                engine,
                inputContinuation,
                runTask,
                analyzer,
                inputPool,
                convertedPool,
                inputSignal
            )
            isRunning = false
            engine = nil
            inputContinuation = nil
            runTask = nil
            analyzer = nil
            inputPool = nil
            convertedPool = nil
            inputSignal = nil
            converter = nil
            return state
        }
    }

    private func shutdownCapture() {
        let state = takeRunState()
        state.engine?.inputNode.removeTap(onBus: 0)
        state.engine?.stop()
        state.inputPool?.close()
        state.inputSignal?.finish()
        deactivateAudioSession()
    }

    private func shutdownSynchronously() {
        let state = takeRunState()
        state.engine?.inputNode.removeTap(onBus: 0)
        state.engine?.stop()
        state.inputPool?.close()
        state.inputSignal?.finish()
        state.continuation?.finish(throwing: CancellationError())
        state.task?.cancel()
        deactivateAudioSession()
    }

    private func stopEngineOnly() {
        let engine = lock.withLock { self.engine }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        deactivateAudioSession()
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }

    private func cancelCurrentRun() async {
        let running = lock.withLock { isRunning }
        if running {
            await cancel()
        }
    }

    private func convertedCapacity(
        sourceFormat: AVAudioFormat,
        targetFormat: AVAudioFormat
    ) -> AVAudioFrameCount {
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        return AVAudioFrameCount(Double(Self.inputBufferSize) * ratio + 64)
    }
}
