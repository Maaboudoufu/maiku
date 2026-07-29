import AVFoundation
import Foundation

// WhisperKit predates Swift 6 strict concurrency and its own types are not
// marked Sendable, even though calling its async API from a single actor, one
// call at a time — exactly how this actor uses it — is safe in practice.
// `@preconcurrency` downgrades those unannotated-concurrency diagnostics to
// warnings without weakening checking anywhere else in this module.
@preconcurrency import WhisperKit

/// Segments emitted mid-stream carry this in place of a real recording id.
///
/// `SpeechTranscribing` is deliberately recording-agnostic (`prepare`/
/// `startStreaming` take no recording identity), so this adapter cannot know
/// which recording it is transcribing for. Whoever owns that context —
/// `RecordingCoordinator` — must overwrite `recordingID` before anything is
/// persisted. It is a fixed, recognisable placeholder rather than a fresh
/// random id so a forgotten overwrite fails loudly instead of silently
/// scattering unrelated UUIDs into the database.
public let unassignedRecordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

/// WhisperKit behind `SpeechTranscribing` (plan §5.2).
///
/// Verified against a real transcription in the Milestone 0 spike:
/// `WhisperKitConfig(model:)` → `WhisperKit(_:)` → `transcribe(audioPath:)` /
/// `transcribe(audioArray:decodeOptions:)`. That spike also found segment
/// text still carrying WhisperKit's special tokens
/// (`"<|startoftranscript|>…"`), which is why every string below passes
/// through `TranscriptTokenSanitizer` before it leaves this file.
public actor WhisperKitTranscriber: SpeechTranscribing {

    /// How much *new* audio to accumulate before re-transcribing the window.
    /// Sits inside plan §18's "roughly two to five seconds" live-transcript
    /// latency target.
    private static let flushInterval: TimeInterval = 3

    /// Text ending within this long of the window's leading edge is still
    /// close enough to "what was just said" that more context could revise
    /// it — kept as `unstableText` rather than emitted as final.
    private static let unstableTail: TimeInterval = 2

    /// Hard ceiling on retained audio (plan §6.2, §18): a 2-hour recording
    /// must not grow this buffer without bound. Every flush trims the window
    /// back down to `unstableTail` plus this much overlap, so the next
    /// window still has enough context to resolve a word split across the
    /// boundary.
    private static let overlap: TimeInterval = 1
    private static let maxWindowDuration: TimeInterval = 30

    private var whisperKit: WhisperKit?
    private var modelConfiguration: SpeechModelConfiguration?

    // Streaming state
    private var windowSamples: [Float] = []
    private var windowStartTime: TimeInterval = 0
    private var newSamplesSinceFlush: Int = 0
    private var stableBoundary: TimeInterval = 0
    private var emittedStableSegments: [TranscriptSegment] = []
    private var continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation?

    /// `nonisolated(unsafe)`: `SpeechTranscribing.updates()` is declared
    /// synchronous, so an actor can only satisfy it with a `nonisolated`
    /// method — which cannot touch actor-isolated state at all, yet the
    /// stream has to be replaced every `startStreaming()` (a new recording
    /// needs a fresh, unfinished stream; the previous one was finished by
    /// the prior recording's `finishStreaming()`). Safe under the one
    /// invariant every caller already follows: `await startStreaming()`
    /// completes before `updates()` is read for that recording, and nothing
    /// else ever writes this property.
    nonisolated(unsafe) private var updateStream = AsyncThrowingStream<TranscriptionUpdate, Error> { $0.finish() }

    public init() {}

    public func prepare(model: SpeechModelConfiguration) async throws {
        modelConfiguration = model
        do {
            let config = WhisperKitConfig(model: model.modelName)
            config.verbose = false
            config.logLevel = .error
            whisperKit = try await WhisperKit(config)
        } catch {
            throw MaikuError.speechModelLoadFailed(name: model.modelName, underlying: error.localizedDescription)
        }
    }

    public func startStreaming() async throws {
        windowSamples = []
        windowStartTime = 0
        newSamplesSinceFlush = 0
        stableBoundary = 0
        emittedStableSegments = []
        var newContinuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation!
        updateStream = AsyncThrowingStream { newContinuation = $0 }
        continuation = newContinuation
    }

    public nonisolated func updates() -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        updateStream
    }

    /// `nonisolated`: `AVAudioPCMBuffer` is not `Sendable`, so it can never
    /// cross into this actor's isolation. The samples are copied out into a
    /// plain, Sendable `[Float]` here, in the caller's isolation domain,
    /// before anything is handed to actor-isolated state.
    public nonisolated func accept(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) async throws {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        try await ingest(samples, sampleRate: Double(buffer.format.sampleRate), at: time)
    }

    private func ingest(_ samples: [Float], sampleRate: Double, at time: TimeInterval) async throws {
        if windowSamples.isEmpty { windowStartTime = time }
        windowSamples.append(contentsOf: samples)
        newSamplesSinceFlush += samples.count

        guard sampleRate > 0, Double(newSamplesSinceFlush) / sampleRate >= Self.flushInterval else { return }
        newSamplesSinceFlush = 0
        try await flush(sampleRate: sampleRate)
    }

    public func finishStreaming() async throws -> FinalTranscription {
        if !windowSamples.isEmpty {
            try await flush(sampleRate: Double(SpeechAudioChunk.format.sampleRate), isFinal: true)
        }
        continuation?.finish()
        let modelName = modelConfiguration?.modelName ?? ""
        return FinalTranscription(segments: emittedStableSegments, modelName: modelName)
    }

    public func transcribeFile(at url: URL) async throws -> FinalTranscription {
        guard let whisperKit else {
            throw MaikuError.speechModelLoadFailed(name: modelConfiguration?.modelName ?? "unknown", underlying: "prepare(model:) was not called.")
        }
        do {
            // Higher-accuracy final pass (plan §6.5 step 3): VAD-based chunking
            // handles a long file's silences better than one giant window, and
            // word timestamps are needed for alignment against diarization.
            let options = DecodingOptions(
                language: modelConfiguration?.language,
                temperature: 0,
                wordTimestamps: true,
                chunkingStrategy: .vad)
            let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)
            return Self.finalTranscription(from: results, modelName: modelConfiguration?.modelName ?? "")
        } catch let error as MaikuError {
            throw error
        } catch {
            throw MaikuError.transcriptionFailed(error.localizedDescription)
        }
    }

    // MARK: - Streaming internals

    private func flush(sampleRate: Double, isFinal: Bool = false) async throws {
        guard let whisperKit else {
            throw MaikuError.speechModelLoadFailed(name: modelConfiguration?.modelName ?? "unknown", underlying: "prepare(model:) was not called.")
        }
        let options = DecodingOptions(
            language: modelConfiguration?.language, temperature: 0, wordTimestamps: true)

        let results: [TranscriptionResult]
        do {
            results = try await whisperKit.transcribe(audioArray: windowSamples, decodeOptions: options)
        } catch {
            throw MaikuError.transcriptionFailed(error.localizedDescription)
        }

        let windowEnd = windowStartTime + Double(windowSamples.count) / sampleRate
        let absoluteSegments = results.flatMap(\.segments).map { segment in
            StreamingMerge.Segment(
                start: windowStartTime + Double(segment.start),
                end: windowStartTime + Double(segment.end),
                text: TranscriptTokenSanitizer.clean(segment.text))
        }

        let outcome = StreamingMerge.merge(
            segments: absoluteSegments,
            previousStableBoundary: stableBoundary,
            windowEndTime: windowEnd,
            unstableTail: isFinal ? 0 : Self.unstableTail)

        let newStable = outcome.newlyStable.map { seg in
            TranscriptSegment(
                recordingID: unassignedRecordingID, startTime: seg.start, endTime: seg.end,
                text: seg.text, isFinal: isFinal, source: .live)
        }
        emittedStableSegments.append(contentsOf: newStable)
        stableBoundary = outcome.newStableBoundary

        continuation?.yield(
            TranscriptionUpdate(
                stableSegments: newStable, unstableText: outcome.unstableText, windowStart: windowStartTime))

        guard !isFinal else { return }

        // Trim the window: everything before (stableBoundary - overlap) has
        // already been emitted and is kept only so the next transcription
        // pass has enough left-context to resolve a word split at the cut.
        let retainFrom = max(0, stableBoundary - Self.overlap - windowStartTime)
        let dropSamples = min(windowSamples.count, Int(retainFrom * sampleRate))
        if dropSamples > 0 {
            windowSamples.removeFirst(dropSamples)
            windowStartTime += Double(dropSamples) / sampleRate
        }
        // Absolute ceiling in case transcription falls behind real time —
        // never let the buffer itself grow unbounded (plan §6.2, §18).
        let maxSamples = Int(Self.maxWindowDuration * sampleRate)
        if windowSamples.count > maxSamples {
            let excess = windowSamples.count - maxSamples
            windowSamples.removeFirst(excess)
            windowStartTime += Double(excess) / sampleRate
        }
    }

    private static func finalTranscription(from results: [TranscriptionResult], modelName: String) -> FinalTranscription {
        let segments = results.flatMap(\.segments).map { segment in
            TranscriptSegment(
                recordingID: unassignedRecordingID,
                startTime: TimeInterval(segment.start),
                endTime: TimeInterval(segment.end),
                text: TranscriptTokenSanitizer.clean(segment.text),
                isFinal: true,
                source: .final)
        }
        let words = results.flatMap(\.segments).compactMap(\.words).flatMap { $0 }.map { word in
            TranscriptWord(
                text: TranscriptTokenSanitizer.clean(word.word),
                startTime: TimeInterval(word.start),
                endTime: TimeInterval(word.end),
                confidence: Double(word.probability))
        }
        return FinalTranscription(
            segments: segments, words: words, detectedLanguage: results.first?.language, modelName: modelName)
    }
}

/// Pure timestamp-based merging for the rolling transcription window (plan
/// §6.3: "stable and unstable text ranges", "timestamp-aware merging to
/// remove duplicates caused by overlap"). Free of WhisperKit so it can be
/// tested without a model, a microphone, or a file.
enum StreamingMerge {
    struct Segment: Equatable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    struct Outcome: Equatable {
        var newlyStable: [Segment]
        var unstableText: String
        var newStableBoundary: TimeInterval
    }

    /// - Parameters:
    ///   - segments: every segment WhisperKit produced for the *current*
    ///     window, in absolute recording time. Re-transcribing the whole
    ///     window each flush means this always includes segments already
    ///     emitted as stable — those are filtered out here, not re-emitted.
    ///   - previousStableBoundary: the boundary returned by the previous call.
    ///   - unstableTail: seconds back from the window's end still considered
    ///     revisable. Zero collapses everything into stable, which is what a
    ///     final flush wants.
    static func merge(
        segments: [Segment], previousStableBoundary: TimeInterval, windowEndTime: TimeInterval,
        unstableTail: TimeInterval
    ) -> Outcome {
        let boundary = max(previousStableBoundary, windowEndTime - unstableTail)
        let newlyStable = segments
            .filter { $0.end > previousStableBoundary && $0.end <= boundary }
            .sorted { $0.start < $1.start }
        let unstableText = segments
            .filter { $0.end > boundary }
            .sorted { $0.start < $1.start }
            .map(\.text)
            .joined(separator: " ")
        return Outcome(newlyStable: newlyStable, unstableText: unstableText, newStableBoundary: boundary)
    }
}
