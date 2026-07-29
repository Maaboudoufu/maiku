import Foundation

/// Strict JSON Schemas for the two organization passes (plan §7.2, §7.3).
///
/// These mirror `OrganizedRecording` and `ChunkSummary` field for field, minus
/// `id`: the model is never asked to mint UUIDs. That wastes tokens, and a
/// single malformed one would fail the whole decode — `LMStudioClient` fills
/// them in instead.
///
/// Schemas are built by function, not stored in a global, so nothing has to be
/// shared across isolation domains.
enum OrganizationSchema {

    /// Pass 2 — one coherent result for the whole recording.
    static func finalReduction() -> [String: Any] {
        object([
            "title": str("Six words or fewer. Plain, specific, no filler."),
            "shortSummary": str("One or two sentences a reader can scan."),
            "detailedSummary": str("A paragraph or two covering what happened and why."),
            "organizedSections": list(section(), "The meeting rewritten as readable sections."),
            "keyTakeaways": list(sourcedStatement(), "The points that matter most."),
            "decisions": list(decision(), "Only choices the transcript states were made."),
            "actionItems": list(actionItem(), "Only tasks the transcript states were agreed."),
            "openQuestions": list(sourcedStatement(), "Questions raised and left unanswered."),
            "followUps": list(sourcedStatement(), "Things the participants said they would revisit."),
            "quotes": list(quote(), "Verbatim lines worth keeping."),
            "topics": list(topic(), "What was discussed, in order."),
            "tags": list(
                ["type": "string"], "A few lowercase keywords. No invented project names."),
            "speakerSummary": list(speakerSummary(), "One entry per listed speaker."),
        ])
    }

    /// Pass 1 — what a single chunk supports on its own.
    static func chunkExtraction() -> [String: Any] {
        object([
            "summary": str("What happens in this chunk only."),
            "topics": list(topic(), "Topics discussed in this chunk."),
            "keyPoints": list(sourcedStatement(), "Points this chunk supports."),
            "decisions": list(decision(), "Decisions stated in this chunk."),
            "actionItems": list(actionItem(), "Tasks agreed in this chunk."),
            "openQuestions": list(sourcedStatement(), "Questions left open in this chunk."),
            "quotes": list(quote(), "Candidate verbatim quotes from this chunk."),
            "tags": list(["type": "string"], "Candidate lowercase keywords."),
        ])
    }

    // MARK: - Shared object shapes

    private static func sourcedStatement() -> [String: Any] {
        object([
            "text": str("The claim, in one sentence."),
            "sourceSegmentIDs": segmentIDs,
            "confidence": confidence,
        ])
    }

    private static func section() -> [String: Any] {
        object([
            "heading": str("Short heading."),
            "body": str("Plain prose. No markdown headings."),
            "sourceSegmentIDs": segmentIDs,
        ])
    }

    private static func decision() -> [String: Any] {
        object([
            "text": str("The decision as it was made."),
            "rationale": nullableStr("Why, if the transcript says. Otherwise null."),
            "sourceSegmentIDs": segmentIDs,
            "confidence": confidence,
        ])
    }

    private static func actionItem() -> [String: Any] {
        object([
            "task": str("What has to be done, phrased as the transcript puts it."),
            "ownerSpeakerID": nullableStr(
                "An id copied from the speaker list, or null. Never a name."),
            "ownerText": nullableStr(
                "The owner exactly as spoken when they are not a listed speaker, else null."),
            "dueDateISO8601": nullableStr(
                "yyyy-MM-dd only when the transcript states an absolute date. Relative wording "
                    + "such as \"next Tuesday\" stays in task and this stays null."),
            "status": ["type": "string", "enum": ["open"]],
            "sourceSegmentIDs": segmentIDs,
            "confidence": confidence,
        ])
    }

    private static func quote() -> [String: Any] {
        object([
            "exactText": str("Copied word for word from the cited segment."),
            "speakerID": nullableStr("An id copied from the speaker list, or null."),
            "segmentID": str("The id of the segment this line comes from."),
            "startTime": num("Copy the cited segment's start, in seconds."),
            "endTime": num("Copy the cited segment's end, in seconds."),
        ])
    }

    private static func topic() -> [String: Any] {
        object([
            "name": str("A few words."),
            "startTime": nullableNum("Seconds, or null."),
            "endTime": nullableNum("Seconds, or null."),
            "sourceSegmentIDs": segmentIDs,
        ])
    }

    private static func speakerSummary() -> [String: Any] {
        object([
            "speakerID": nullableStr("An id copied from the speaker list, or null."),
            "displayName": str("The name shown in the speaker list."),
            "contribution": str("What this speaker contributed, in one or two sentences."),
            "speakingTimeSeconds": nullableNum("Seconds, or null when unknown."),
        ])
    }

    // MARK: - Primitives

    /// Strict mode demands `additionalProperties: false` and every property
    /// listed in `required`; deriving both from the properties keeps them from
    /// drifting apart as fields are added.
    private static func object(_ properties: [String: Any]) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": properties.keys.sorted(),
            "additionalProperties": false,
        ]
    }

    private static func list(_ items: [String: Any], _ description: String) -> [String: Any] {
        ["type": "array", "items": items, "description": description]
    }

    private static func str(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    /// Nullable fields must be declared as a type union. Declared this way the
    /// model returns null instead of inventing an owner or a due date; declared
    /// as a plain string it invents one (Milestone 0 spike).
    private static func nullableStr(_ description: String) -> [String: Any] {
        ["type": ["string", "null"], "description": description]
    }

    private static func num(_ description: String) -> [String: Any] {
        ["type": "number", "description": description]
    }

    private static func nullableNum(_ description: String) -> [String: Any] {
        ["type": ["number", "null"], "description": description]
    }

    private static var segmentIDs: [String: Any] {
        list(
            ["type": "string"],
            "One or more segment ids copied character for character from the transcript. "
                + "Never empty, never invented.")
    }

    private static var confidence: [String: Any] {
        num("0 to 1 — how directly the transcript supports this. Below 0.5 if you are inferring.")
    }
}
