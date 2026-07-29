import AVFoundation
import Foundation

/// One snapshot of playback, for the transcript scrubber and the
/// currently-playing segment highlight (plan §10.6).
public struct PlaybackState: Sendable, Equatable {
    public var currentTime: TimeInterval
    public var duration: TimeInterval
    public var isPlaying: Bool
    public var rate: Float

    public init(currentTime: TimeInterval, duration: TimeInterval, isPlaying: Bool, rate: Float) {
        self.currentTime = currentTime
        self.duration = duration
        self.isPlaying = isPlaying
        self.rate = rate
    }
}

/// What the detail screen needs from audio playback, abstracted the same way
/// `AudioCapturing` abstracts the microphone — so a UI test could drive it
/// with a fake rather than a real audio file.
public protocol AudioPlaying: Sendable {
    var state: AsyncStream<PlaybackState> { get }
    func load(url: URL) async throws
    func play() async throws
    func pause() async
    func seek(to time: TimeInterval) async
    func setRate(_ rate: Float) async
    func stop() async
    /// The current state without waiting on `state`'s next emission —
    /// useful right after a call like `seek(to:)` whose effect is already
    /// known synchronously from the caller's point of view.
    func currentState() async -> PlaybackState?
}

/// Plays a recording's archived audio (plan §10.6's "persistent compact audio
/// player with scrubber and playback speed").
///
/// `AVAudioPlayer` is not documented as thread-safe, so every access to it —
/// including the periodic position poll — goes through this actor's serial
/// executor rather than, say, an `AVAudioPlayerDelegate` callback arriving on
/// an arbitrary thread.
public actor AudioPlaybackService: AudioPlaying {
    public nonisolated let state: AsyncStream<PlaybackState>
    private nonisolated let stateContinuation: AsyncStream<PlaybackState>.Continuation
    private let pollInterval: Duration

    private var player: AVAudioPlayer?
    private var pollTask: Task<Void, Never>?

    public init(pollInterval: Duration = .milliseconds(100)) {
        self.pollInterval = pollInterval
        let stream = AsyncStream<PlaybackState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        state = stream.stream
        stateContinuation = stream.continuation
    }

    public func load(url: URL) throws {
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true
            player.prepareToPlay()
            self.player = player
            emit()
        } catch {
            throw MaikuError.fileIntegrityCheckFailed(path: url.path)
        }
    }

    public func play() throws {
        guard let player else {
            throw MaikuError.audioEngineFailed("No audio loaded.")
        }
        guard player.play() else {
            throw MaikuError.audioEngineFailed("The audio device refused to start playback.")
        }
        startPolling()
    }

    public func pause() {
        player?.pause()
        stopPolling()
        emit()
    }

    /// Clamped just short of the file's duration — a segment timestamp a
    /// hair past the end, from floating-point drift, must not throw playback
    /// into a confusing state. `AVAudioPlayer` silently ignores an assignment
    /// to `currentTime` at or beyond `duration` (verified empirically: the
    /// property is simply left unchanged), so the ceiling has to sit strictly
    /// under it, not at it.
    public func seek(to time: TimeInterval) {
        guard let player else { return }
        let ceiling = max(0, player.duration - 0.05)
        player.currentTime = max(0, min(time, ceiling))
        emit()
    }

    public func setRate(_ rate: Float) {
        guard let player else { return }
        player.rate = rate
        emit()
    }

    public func stop() {
        player?.stop()
        stopPolling()
        player = nil
    }

    public func currentState() -> PlaybackState? {
        guard let player else { return nil }
        return PlaybackState(
            currentTime: player.currentTime, duration: player.duration,
            isPlaying: player.isPlaying, rate: player.rate)
    }

    // MARK: Private

    private func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, await self.pollOnce() else { return }
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Emits unconditionally, then reports whether the caller should keep
    /// polling. Emitting only while `isPlaying` would miss the exact moment
    /// `AVAudioPlayer` stops itself at end-of-file — the UI would keep
    /// showing "playing" forever with no further updates.
    @discardableResult
    private func pollOnce() -> Bool {
        emit()
        return player?.isPlaying ?? false
    }

    private func emit() {
        guard let player else { return }
        stateContinuation.yield(
            PlaybackState(
                currentTime: player.currentTime, duration: player.duration,
                isPlaying: player.isPlaying, rate: player.rate))
    }
}
