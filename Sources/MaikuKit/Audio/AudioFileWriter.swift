import AVFoundation
import Foundation

/// Append-only writer for the lossless working file (plan §6.2).
///
/// CAF rather than WAV: Core Audio leaves the CAF data chunk's size open-ended
/// while writing, so a file abandoned by a crash or a yanked cable still plays
/// and still reads back. A WAV truncated mid-recording has a lying header.
///
/// Not thread-safe on purpose — `AudioCaptureService` owns the only instance and
/// serialises access behind its own lock.
public final class AudioFileWriter {

    public let url: URL
    public private(set) var framesWritten: AVAudioFramePosition = 0

    private let processingFormat: AVAudioFormat
    private var file: AVAudioFile?

    /// - Parameter format: used for both the file format and the processing
    ///   format, so writing a tap buffer costs no conversion at all.
    public init(url: URL, format: AVAudioFormat) throws {
        guard url.isFileURL else {
            throw MaikuError.audioFileWriteFailed("\(url) is not a file URL.")
        }
        self.url = url
        self.processingFormat = format
        do {
            self.file = try AVAudioFile(
                forWriting: url, settings: format.settings,
                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        } catch {
            throw MaikuError.audioFileWriteFailed(error.localizedDescription)
        }
    }

    /// Appends a buffer.
    ///
    /// The format check is not paranoia: `AVAudioFile.write(from:)` raises an
    /// Objective-C exception on a mismatch, which Swift cannot catch, so the
    /// process would die holding an unclosed recording.
    public func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let file else {
            throw MaikuError.audioFileWriteFailed("The recording file is already closed.")
        }
        guard buffer.format.sampleRate == processingFormat.sampleRate,
            buffer.format.channelCount == processingFormat.channelCount,
            buffer.format.commonFormat == processingFormat.commonFormat
        else {
            throw MaikuError.audioFileWriteFailed("The input format changed mid-recording.")
        }
        guard buffer.frameLength > 0 else { return }

        do {
            try file.write(from: buffer)
        } catch {
            throw MaikuError.audioFileWriteFailed(error.localizedDescription)
        }
        framesWritten += AVAudioFramePosition(buffer.frameLength)
    }

    /// Closes the file. Releasing the `AVAudioFile` is what flushes Core Audio's
    /// write buffer and patches the CAF header. Idempotent.
    ///
    /// ponytail: `AVAudioFile` exposes no incremental flush, so a hard crash can
    /// still lose Core Audio's last internal buffer — well under a second, and
    /// the rest of the file stays playable. Upgrade path if that matters:
    /// `ExtAudioFile` plus a periodic `AudioFileFlush`.
    public func close() {
        file = nil
    }

    /// Frame count of a finished file — how finalization validates the working
    /// file before spending minutes transcribing it (plan §6.5 step 1).
    public static func frameCount(at url: URL) throws -> AVAudioFramePosition {
        do {
            return try AVAudioFile(forReading: url).length
        } catch {
            throw MaikuError.fileIntegrityCheckFailed(path: url.path)
        }
    }
}
