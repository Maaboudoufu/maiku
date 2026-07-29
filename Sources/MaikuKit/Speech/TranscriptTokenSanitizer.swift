import Foundation

/// Removes Whisper's control vocabulary from decoded text.
///
/// WhisperKit hands back segment text with the raw tokens still embedded —
/// `"<|startoftranscript|><|0.00|> Good morning everyone<|4.16|>"` — and every one of
/// them has to be gone before the text reaches the database, the LM, or an export.
/// Setting `skipSpecialTokens` on the decoder is not enough on its own: the Milestone 0
/// spike saw tokens survive into `segment.text`, so this runs on everything.
public enum TranscriptTokenSanitizer {

    /// The longest token Whisper emits is `startoftranscript` (17 characters). The cap
    /// stops a stray `"<|"` in real speech from swallowing the rest of the line.
    private static let maxTokenLength = 40

    /// Strips `<|…|>` tokens and collapses the whitespace they leave behind.
    public static func clean(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        var i = raw.startIndex
        while i < raw.endIndex {
            if let afterToken = endOfToken(in: raw, at: i) {
                // A token can sit between two words; keep them apart.
                out.append(" ")
                i = afterToken
            } else {
                out.append(raw[i])
                i = raw.index(after: i)
            }
        }
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Index just past the closing `|>` when a well-formed token starts at `i`, else nil.
    ///
    /// Whisper tokens never contain whitespace or angle brackets, so anything that does
    /// is left alone rather than silently deleted from someone's transcript.
    private static func endOfToken(in s: String, at i: String.Index) -> String.Index? {
        guard s[i] == "<" else { return nil }
        var j = s.index(after: i)
        guard j < s.endIndex, s[j] == "|" else { return nil }
        j = s.index(after: j)

        var scanned = 0
        while j < s.endIndex, scanned < maxTokenLength {
            let c = s[j]
            if c == "|" {
                let k = s.index(after: j)
                return k < s.endIndex && s[k] == ">" ? s.index(after: k) : nil
            }
            if c == "<" || c == ">" || c.isWhitespace { return nil }
            j = s.index(after: j)
            scanned += 1
        }
        return nil
    }
}
