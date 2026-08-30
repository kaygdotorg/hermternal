import HermternalCore
import AudioToolbox
import AVFoundation
import Foundation
import os.lock

/// Errors from microphone capture and file-backed recording.
public enum AudioCaptureAdapterError: LocalizedError, Sendable {
    case microphonePermissionDenied
    case alreadyRecording
    case notRecording
    case noInputDevice
    case invalidInputFormat
    case couldNotCreateFile(String)
    case captureFailed(String)
    case maximumDurationExceeded
    case maximumSizeExceeded

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is required for audio recording."
        case .alreadyRecording:
            return "An audio recording is already in progress."
        case .notRecording:
            return "No audio recording is in progress."
        case .noInputDevice:
            return "No microphone is available."
        case .invalidInputFormat:
            return "The microphone returned an invalid audio format."
        case .couldNotCreateFile(let reason):
            return "The audio file could not be created: \(reason)"
        case .captureFailed(let reason):
            return "Audio recording failed: \(reason)"
        case .maximumDurationExceeded:
            return "Audio recording stopped: the 60-second duration limit was reached."
        case .maximumSizeExceeded:
            return "Audio recording stopped: the 50 MiB file-size limit was reached."
        }
    }
}

/// A preallocated, bounded PCM ring for the real-time input callback.
private final class PCMBufferPool: @unchecked Sendable {
    fileprivate final class BufferBox: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }
    private struct SourceBox: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }
    
    private final class State: @unchecked Sendable {
        var free: [BufferBox]
        var ready: [BufferBox?]
        var readyHead = 0
        var readyCount = 0
        var closed = false
        var failure: AudioCaptureAdapterError?

        init(format: AVAudioFormat, capacity: Int, frameCapacity: AVAudioFrameCount) {
            free = (0..<capacity).compactMap { _ in
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: frameCapacity
                ) else {
                    return nil
                }
                return BufferBox(buffer)
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

    func enqueue(_ source: AVAudioPCMBuffer) -> Bool {
        let sourceBox = SourceBox(source)
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

    func dequeue() -> BufferBox? {
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

    func release(_ slot: BufferBox) {
        lock.withLock { $0.free.append(slot) }
    }

    func close() {
        lock.withLock { $0.closed = true }
    }

    func isClosedAndEmpty() -> Bool {
        lock.withLock { $0.closed && $0.readyCount == 0 }
    }

    func failureIfAny() -> AudioCaptureAdapterError? {
        lock.withLock { $0.failure }
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

/// Writes a bounded PCM ring from a serial queue.
private final class AudioCaptureWriter: @unchecked Sendable {
    private static let poolCapacity = 32
    private static let bufferSize: AVAudioFrameCount = 1_024
    static let maximumFileBytes = 50 * 1024 * 1024
    /// A one-minute cap is below 50 MiB for ordinary microphone formats; the
    /// payload cap below also handles high-rate or multi-channel devices.
    static let maximumDurationSeconds: Double = 60
    private static let headerSafetyBytes = 64 * 1024

    let pool: PCMBufferPool
    private let file: AVAudioFile
    private let bytesPerFrame: Int
    private let maximumFrames: AVAudioFramePosition
    private let durationLimited: Bool
    private let onTerminalFailure: @Sendable () -> Void
    private let queue = DispatchQueue(label: "org.hermternal.audio-capture-writer", qos: .utility)
    private let signal = DispatchSemaphore(value: 0)
    private let failureGate = DispatchSemaphore(value: 1)
    private var frameCount: AVAudioFramePosition = 0

    init(
        file: AVAudioFile,
        format: AVAudioFormat,
        onTerminalFailure: @escaping @Sendable () -> Void
    ) {
        self.file = file
        bytesPerFrame = max(1, Int(format.streamDescription.pointee.mBytesPerFrame))
        let payloadLimit = Self.maximumFileBytes - Self.headerSafetyBytes
        let byteFrames = AVAudioFramePosition(payloadLimit / bytesPerFrame)
        let durationFrames = AVAudioFramePosition(
            format.sampleRate * Self.maximumDurationSeconds
        )
        maximumFrames = min(byteFrames, durationFrames)
        durationLimited = durationFrames <= byteFrames
        self.onTerminalFailure = onTerminalFailure
        pool = PCMBufferPool(
            format: format,
            capacity: Self.poolCapacity,
            frameCapacity: Self.bufferSize
        )
        queue.async { [self] in run() }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard pool.enqueue(buffer) else {
            reportOverflow()
            return false
        }
        signal.signal()
        return true
    }

    /// Reports a full or busy pool once without blocking the input callback.
    private func reportOverflow() {
        guard failureGate.wait(timeout: .now()) == .success else { return }
        queue.async { [self] in
            recordTerminalFailure(.captureFailed("Audio buffer pool exhausted."))
            failureGate.signal()
        }
    }

    func finish() {
        pool.close()
        signal.signal()
        queue.sync {}
    }

    var durationFrames: AVAudioFramePosition { frameCount }
    var failure: AudioCaptureAdapterError? { pool.failureIfAny() }

    private func run() {
        while true {
            signal.wait()
            while let item = pool.dequeue() {
                defer { pool.release(item) }
                let remaining = maximumFrames - frameCount
                guard remaining > 0 else {
                    recordTerminalFailure(
                        durationLimited ? .maximumDurationExceeded : .maximumSizeExceeded
                    )
                    break
                }
                let framesToWrite = min(
                    AVAudioFramePosition(item.buffer.frameLength),
                    remaining
                )
                item.buffer.frameLength = AVAudioFrameCount(framesToWrite)
                do {
                    try file.write(from: item.buffer)
                    frameCount += framesToWrite
                } catch {
                    recordTerminalFailure(.captureFailed("Audio file write failed."))
                    break
                }
                if frameCount >= maximumFrames {
                    recordTerminalFailure(
                        durationLimited ? .maximumDurationExceeded : .maximumSizeExceeded
                    )
                    break
                }
            }
            if pool.isClosedAndEmpty() { return }
        }
    }

    private func recordTerminalFailure(_ failure: AudioCaptureAdapterError) {
        let shouldNotify = pool.recordFailureIfAbsent(failure)
        pool.close()
        guard shouldNotify else { return }
        onTerminalFailure()
    }
}

/// Records from one AVAudioEngine input tap into an incrementally written CAF file.
///
/// The real-time callback only copies into a preallocated 32-slot PCM ring and
/// signals a serial writer. It never writes a file or waits on a contended lock.
/// Dictation and recording are mutually exclusive at the Composer state seam.
@available(macOS 26.0, iOS 26.0, *)
public final class AudioCaptureAdapter: AudioRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var writer: AudioCaptureWriter?
    private var outputURL: URL?
    private var sampleRate: Double = 0
    private var isRunning = false

    public init() {}

    deinit {
        shutdownSynchronously()
    }

    public func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    public func start(into directory: URL) async throws {
        try Task.checkCancellation()
        guard await requestPermission() else {
            throw AudioCaptureAdapterError.microphonePermissionDenied
        }

        let alreadyRunning = lock.withLock { isRunning }
        guard !alreadyRunning else {
            throw AudioCaptureAdapterError.alreadyRecording
        }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )

            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true)
            #endif

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.channelCount > 0 else {
                throw AudioCaptureAdapterError.noInputDevice
            }
            guard format.sampleRate > 0 else {
                throw AudioCaptureAdapterError.invalidInputFormat
            }

            let fileURL = directory
                .appendingPathComponent("recording-\(UUID().uuidString)")
                .appendingPathExtension("caf")
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
            } catch {
                throw AudioCaptureAdapterError.couldNotCreateFile("The recording file could not be created.")
            }
            let writer = AudioCaptureWriter(
                file: file,
                format: format,
                onTerminalFailure: { [weak self] in
                    self?.stopEngineOnly()
                }
            )

            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) {
                [writer] buffer, _ in
                _ = writer.enqueue(buffer)
            }

            lock.withLock {
                self.engine = engine
                self.writer = writer
                self.outputURL = fileURL
                self.sampleRate = format.sampleRate
                self.isRunning = true
            }

            do {
                try engine.start()
            } catch {
                let failedState = takeState()
                failedState.engine?.inputNode.removeTap(onBus: 0)
                failedState.engine?.stop()
                failedState.writer?.finish()
                try? FileManager.default.removeItem(at: fileURL)
                throw AudioCaptureAdapterError.captureFailed("Audio engine failed to start.")
            }
        } catch let error as AudioCaptureAdapterError {
            deactivateAudioSession()
            throw error
        } catch {
            deactivateAudioSession()
            throw AudioCaptureAdapterError.captureFailed("Audio recording setup failed.")
        }
    }
    public func stop() async throws -> AudioRecordingResult {
        let state = takeState()
        guard let engine = state.engine, let writer = state.writer, let outputURL = state.outputURL else {
            deactivateAudioSession()
            throw AudioCaptureAdapterError.notRecording
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer.finish()
        deactivateAudioSession()

        if let failure = writer.failure {
            try? FileManager.default.removeItem(at: outputURL)
            throw failure
        }
        let byteCount = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard byteCount <= AudioCaptureWriter.maximumFileBytes else {
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioCaptureAdapterError.maximumSizeExceeded
        }
        let duration = state.sampleRate > 0
            ? Duration.seconds(Double(writer.durationFrames) / state.sampleRate)
            : .zero
        return AudioRecordingResult(fileURL: outputURL, duration: duration, byteCount: byteCount)
    }

    public func cancel() async {
        let state = takeState()
        state.engine?.inputNode.removeTap(onBus: 0)
        state.engine?.stop()
        state.writer?.finish()
        deactivateAudioSession()
        if let outputURL = state.outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    private func takeState() -> (
        engine: AVAudioEngine?,
        writer: AudioCaptureWriter?,
        outputURL: URL?,
        sampleRate: Double
    ) {
        lock.withLock {
            let state = (engine, writer, outputURL, sampleRate)
            isRunning = false
            engine = nil
            writer = nil
            outputURL = nil
            sampleRate = 0
            return state
        }
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
    private func shutdownSynchronously() {
        let state = takeState()
        state.engine?.inputNode.removeTap(onBus: 0)
        state.engine?.stop()
        state.writer?.finish()
        deactivateAudioSession()
        if let outputURL = state.outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
    }
}

private extension PCMBufferPool {
    func recordFailureIfAbsent(_ failure: AudioCaptureAdapterError) -> Bool {
        lock.withLock { state in
            guard state.failure == nil else { return false }
            state.failure = failure
            return true
        }
    }
}
