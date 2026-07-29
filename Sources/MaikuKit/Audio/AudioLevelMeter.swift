import AVFoundation
import Accelerate

/// Input level from a PCM buffer.
///
/// Free functions rather than a stateful meter object: this runs on the audio
/// render thread once per buffer, so it must not allocate and must not need
/// synchronisation of its own (plan §18).
public enum AudioLevelMeter {

    /// Linear RMS and peak magnitude across every channel.
    ///
    /// Both are 0…1 for in-range float audio; `peak` above 1 means the input is
    /// clipping, which the meter should show rather than hide.
    public static func measure(_ buffer: AVAudioPCMBuffer) -> (rms: Float, peak: Float) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return (0, 0) }
        let frames = Int(buffer.frameLength)
        let channelCount = max(1, Int(buffer.format.channelCount))

        if buffer.format.isInterleaved {
            // One allocation holding every channel. RMS over the lot equals the
            // root of the averaged per-channel mean squares, so read it flat.
            return measure(channels[0], count: frames * channelCount)
        }

        var meanSquare: Float = 0
        var peak: Float = 0
        for channel in 0..<channelCount {
            let (channelRMS, channelPeak) = measure(channels[channel], count: frames)
            meanSquare += channelRMS * channelRMS
            peak = max(peak, channelPeak)
        }
        return ((meanSquare / Float(channelCount)).squareRoot(), peak)
    }

    private static func measure(_ samples: UnsafePointer<Float>, count: Int) -> (Float, Float) {
        var rms: Float = 0
        var peak: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
        return (rms, peak)
    }

    /// Maps a linear amplitude onto 0…1 through a decibel scale.
    ///
    /// A linear bar looks dead during speech, which sits near −30 dBFS, so the
    /// meter is logarithmic with everything under `floorDB` pinned to zero.
    public static func normalized(_ amplitude: Float, floorDB: Float = -60) -> Float {
        guard amplitude > 0, floorDB < 0 else { return 0 }
        let db = 20 * log10(min(amplitude, 1))
        guard db > floorDB else { return 0 }
        return (db - floorDB) / -floorDB
    }
}
