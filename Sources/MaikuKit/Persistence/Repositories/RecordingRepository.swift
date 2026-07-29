import Foundation
import GRDB

// MARK: - GRDB conformances for the Core models

/// Row mapping is written out by hand rather than derived from `Codable`.
/// GRDB's automatic Codable-record support would work, but `UUID`'s own
/// `DatabaseValueConvertible` conformance stores a 16-byte BLOB — fine
/// internally, but it makes the database opaque to `sqlite3` and to anyone
/// debugging it by hand. Every id column here is `TEXT` and every id is
/// stored via `.uuidString`, matching the `.text` column type declared in
/// `Migrations.swift`, on purpose.
extension Recording: FetchableRecord, EncodableRecord, PersistableRecord {
    public static let databaseTableName = "recordings"

    public init(row: Row) throws {
        guard let id = UUID(uuidString: row["id"]),
            let status = RecordingStatus(rawValue: row["status"] as String)
        else {
            throw MaikuError.databaseFailure("Malformed row in \(Self.databaseTableName).")
        }
        self.init(
            id: id,
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"],
            title: row["title"],
            status: status,
            recordingStartedAt: row["recordingStartedAt"],
            recordingEndedAt: row["recordingEndedAt"],
            durationSeconds: row["durationSeconds"],
            audioRelativePath: row["audioRelativePath"],
            workingAudioRelativePath: row["workingAudioRelativePath"],
            transcriptionModel: row["transcriptionModel"],
            lmStudioModel: row["lmStudioModel"],
            language: row["language"],
            errorStage: row["errorStage"],
            errorMessage: row["errorMessage"],
            processingProgress: row["processingProgress"],
            trashedAt: row["trashedAt"])
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id.uuidString
        container["createdAt"] = createdAt
        container["updatedAt"] = updatedAt
        container["title"] = title
        container["status"] = status.rawValue
        container["recordingStartedAt"] = recordingStartedAt
        container["recordingEndedAt"] = recordingEndedAt
        container["durationSeconds"] = durationSeconds
        container["audioRelativePath"] = audioRelativePath
        container["workingAudioRelativePath"] = workingAudioRelativePath
        container["transcriptionModel"] = transcriptionModel
        container["lmStudioModel"] = lmStudioModel
        container["language"] = language
        container["errorStage"] = errorStage
        container["errorMessage"] = errorMessage
        container["processingProgress"] = processingProgress
        container["trashedAt"] = trashedAt
    }
}

extension Speaker: FetchableRecord, EncodableRecord, PersistableRecord {
    public static let databaseTableName = "speakers"

    public init(row: Row) throws {
        guard let id = UUID(uuidString: row["id"]),
            let recordingID = UUID(uuidString: row["recordingID"])
        else {
            throw MaikuError.databaseFailure("Malformed row in \(Self.databaseTableName).")
        }
        self.init(
            id: id,
            recordingID: recordingID,
            diarizerLabel: row["diarizerLabel"],
            customName: row["customName"],
            colorIndex: row["colorIndex"])
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id.uuidString
        container["recordingID"] = recordingID.uuidString
        container["diarizerLabel"] = diarizerLabel
        container["customName"] = customName
        container["colorIndex"] = colorIndex
    }
}

extension TranscriptSegment: FetchableRecord, EncodableRecord, PersistableRecord {
    public static let databaseTableName = "transcriptSegments"

    public init(row: Row) throws {
        guard let id = UUID(uuidString: row["id"]),
            let recordingID = UUID(uuidString: row["recordingID"]),
            let source = SegmentSource(rawValue: row["source"] as String)
        else {
            throw MaikuError.databaseFailure("Malformed row in \(Self.databaseTableName).")
        }
        let speakerIDText: String? = row["speakerID"]
        self.init(
            id: id,
            recordingID: recordingID,
            speakerID: speakerIDText.flatMap(UUID.init(uuidString:)),
            startTime: row["startTime"],
            endTime: row["endTime"],
            text: row["text"],
            confidence: row["confidence"],
            isFinal: row["isFinal"],
            source: source)
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id.uuidString
        container["recordingID"] = recordingID.uuidString
        container["speakerID"] = speakerID?.uuidString
        container["startTime"] = startTime
        container["endTime"] = endTime
        container["text"] = text
        container["confidence"] = confidence
        container["isFinal"] = isFinal
        container["source"] = source.rawValue
    }
}

/// The `organizedResults` row: one JSON blob per recording. See the
/// `ponytail:` note on that table in `Migrations.swift`.
private struct OrganizedResultRow: FetchableRecord, EncodableRecord, PersistableRecord {
    static let databaseTableName = "organizedResults"

    var recordingID: UUID
    var json: String
    var updatedAt: Date

    init(recordingID: UUID, json: String, updatedAt: Date) {
        self.recordingID = recordingID
        self.json = json
        self.updatedAt = updatedAt
    }

    init(row: Row) throws {
        guard let recordingID = UUID(uuidString: row["recordingID"]) else {
            throw MaikuError.databaseFailure("Malformed row in \(Self.databaseTableName).")
        }
        self.recordingID = recordingID
        json = row["json"]
        updatedAt = row["updatedAt"]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["recordingID"] = recordingID.uuidString
        container["json"] = json
        container["updatedAt"] = updatedAt
    }
}

// MARK: - Repository

/// The one type product code goes through to read or write a recording and
/// everything derived from it. `GRDB.DatabaseQueue` already serialises its
/// own access, so this is a plain `Sendable` struct rather than an actor —
/// an actor here would only add a redundant hop.
public struct RecordingRepository: Sendable {

    public struct SearchHit: Sendable, Equatable {
        public let recordingID: UUID
        public let titleSnippet: String
        public let transcriptSnippet: String
    }

    private let dbManager: DatabaseManager

    public init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    // MARK: Recordings

    /// Inserts a new recording, or updates it if its id already exists.
    public func save(_ recording: Recording) async throws {
        try await write { db in
            try recording.save(db)
            try Self.rebuildSearchRow(recordingID: recording.id, db: db)
        }
    }

    public func fetch(id: UUID) async throws -> Recording? {
        try await read { db in
            try Recording.filter(key: id.uuidString).fetchOne(db)
        }
    }

    /// Ordered most-recently-started first.
    public func fetchAll(includeTrashed: Bool = false) async throws -> [Recording] {
        try await read { db in
            var request = Recording.order(Column("recordingStartedAt").desc)
            if !includeTrashed {
                request = request.filter(Column("trashedAt") == nil)
            }
            return try request.fetchAll(db)
        }
    }

    /// Recordings left in a non-terminal status — the app was killed,
    /// crashed, or the machine lost power while one was active.
    ///
    /// This doubles as plan §9's "lightweight recovery manifest": rather
    /// than a second, parallel bookkeeping file that could itself drift out
    /// of sync with the database, the `recordings` row already *is* an
    /// atomically-written, durable record of exactly which stage a
    /// recording last reached — `RecordingCoordinator` saves it before
    /// every stage transition. `RecordingCoordinator` always drives a
    /// recording it starts all the way to `.complete` or `.failed` before
    /// returning control, so any row found here at launch could only be
    /// interrupted, never abandoned by ordinary control flow.
    public func fetchInterrupted() async throws -> [Recording] {
        try await read { db in
            try Recording.fetchAll(
                db,
                sql: """
                    SELECT * FROM recordings
                    WHERE status NOT IN ('complete', 'failed', 'trashed')
                    ORDER BY recordingStartedAt DESC
                    """)
        }
    }

    /// Plan §8: trash first, permanent deletion is a separate, explicit step.
    public func trash(id: UUID) async throws {
        try await write { db in
            guard var recording = try Recording.filter(key: id.uuidString).fetchOne(db) else {
                return
            }
            recording.status = .trashed
            recording.trashedAt = Date()
            recording.updatedAt = recording.trashedAt!
            try recording.update(db)
        }
    }

    /// Removes the recording row and, via `ON DELETE CASCADE`, its speakers,
    /// segments and organized result. The FTS index is not reached by that
    /// cascade — SQLite does not enforce foreign keys against virtual
    /// tables — so its row is deleted explicitly in the same transaction.
    /// Does **not** touch audio files; callers own that decision.
    public func deletePermanently(id: UUID) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM recordingSearch WHERE recordingID = ?", arguments: [id.uuidString])
            _ = try Recording.deleteOne(db, key: id.uuidString)
        }
    }

    // MARK: Speakers

    public func upsertSpeakers(_ speakers: [Speaker], recordingID: UUID) async throws {
        try await write { db in
            for speaker in speakers { try speaker.save(db) }
            try Self.rebuildSearchRow(recordingID: recordingID, db: db)
        }
    }

    /// Applies everywhere at once (plan §6.4): the display name is derived
    /// from this one column, read by transcript, notes, quotes and exports.
    public func renameSpeaker(id: UUID, to name: String?) async throws {
        try await write { db in
            guard var speaker = try Speaker.filter(key: id.uuidString).fetchOne(db) else { return }
            speaker.customName = name
            try speaker.update(db)
            try Self.rebuildSearchRow(recordingID: speaker.recordingID, db: db)
        }
    }

    public func fetchSpeakers(recordingID: UUID) async throws -> [Speaker] {
        try await read { db in
            try Speaker
                .filter(Column("recordingID") == recordingID.uuidString)
                .fetchAll(db)
        }
    }

    // MARK: Transcript segments

    /// Replaces every provisional segment for `recordingID` with
    /// `newSegments` in one transaction, except any segment the user has
    /// already edited — plan §6.5 step 6 requires those survive finalization
    /// untouched even though the pass that produced them is being superseded.
    public func replaceSegments(_ newSegments: [TranscriptSegment], recordingID: UUID) async throws {
        try await write { db in
            let preservedIDs = Set(
                try TranscriptSegment
                    .filter(Column("recordingID") == recordingID.uuidString)
                    .filter(Column("source") == SegmentSource.userEdited.rawValue)
                    .fetchAll(db)
                    .map(\.id))
            try db.execute(
                sql: "DELETE FROM transcriptSegments WHERE recordingID = ? AND source != ?",
                arguments: [recordingID.uuidString, SegmentSource.userEdited.rawValue])
            for segment in newSegments where !preservedIDs.contains(segment.id) {
                try segment.insert(db)
            }
            try Self.rebuildSearchRow(recordingID: recordingID, db: db)
        }
    }

    public func fetchSegments(recordingID: UUID) async throws -> [TranscriptSegment] {
        try await read { db in
            try TranscriptSegment
                .filter(Column("recordingID") == recordingID.uuidString)
                .order(Column("startTime"))
                .fetchAll(db)
        }
    }

    // MARK: Organized results

    public func saveOrganizedResult(_ result: OrganizedRecording, recordingID: UUID) async throws {
        let json: String
        do {
            let data = try JSONEncoder().encode(result)
            guard let text = String(data: data, encoding: .utf8) else {
                throw MaikuError.databaseFailure("Organized result was not valid UTF-8 JSON.")
            }
            json = text
        } catch let error as MaikuError {
            throw error
        } catch {
            throw MaikuError.databaseFailure(error.localizedDescription)
        }

        try await write { db in
            let row = OrganizedResultRow(recordingID: recordingID, json: json, updatedAt: Date())
            try row.save(db)
            try Self.rebuildSearchRow(recordingID: recordingID, db: db)
        }
    }

    public func fetchOrganizedResult(recordingID: UUID) async throws -> OrganizedRecording? {
        let json: String? = try await read { db in
            try OrganizedResultRow.filter(key: recordingID.uuidString).fetchOne(db)?.json
        }
        guard let json, let data = json.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(OrganizedRecording.self, from: data)
        } catch {
            throw MaikuError.databaseFailure(error.localizedDescription)
        }
    }

    // MARK: Search

    /// Full-text search across title, transcript, speaker names, and notes
    /// (plan §11.1). Returns nothing for a query with no usable tokens
    /// rather than throwing — an empty search field is not an error.
    public func search(_ query: String) async throws -> [SearchHit] {
        guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return [] }
        return try await read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT recordingID,
                           snippet(recordingSearch, 1, '→', '←', '…', 8) AS titleSnippet,
                           snippet(recordingSearch, 2, '→', '←', '…', 12) AS transcriptSnippet
                    FROM recordingSearch
                    WHERE recordingSearch MATCH ?
                    ORDER BY rank
                    """,
                arguments: [pattern])
            return rows.compactMap { row -> SearchHit? in
                guard let id = UUID(uuidString: row["recordingID"]) else { return nil }
                return SearchHit(
                    recordingID: id,
                    titleSnippet: row["titleSnippet"],
                    transcriptSnippet: row["transcriptSnippet"])
            }
        }
    }

    // MARK: Plumbing

    /// One row per recording, rebuilt wholesale — see the `ponytail:` note
    /// on `recordingSearch` in `Migrations.swift`.
    private static func rebuildSearchRow(recordingID: UUID, db: Database) throws {
        guard let recording = try Recording.filter(key: recordingID.uuidString).fetchOne(db) else {
            // The recording itself was just deleted; nothing to index.
            try db.execute(sql: "DELETE FROM recordingSearch WHERE recordingID = ?", arguments: [recordingID.uuidString])
            return
        }
        let speakers = try Speaker.filter(Column("recordingID") == recordingID.uuidString).fetchAll(db)
        let segments = try TranscriptSegment.filter(Column("recordingID") == recordingID.uuidString).fetchAll(db)
        let organized = try OrganizedResultRow.filter(key: recordingID.uuidString).fetchOne(db)

        let transcriptText = segments.map(\.text).joined(separator: " ")
        let speakerNames = speakers.map(\.displayName).joined(separator: " ")

        var notesText = ""
        var tags = ""
        if let organized, let data = organized.json.data(using: .utf8),
            let result = try? JSONDecoder().decode(OrganizedRecording.self, from: data)
        {
            notesText = ([result.shortSummary, result.detailedSummary]
                + result.organizedSections.map(\.body)
                + result.decisions.map(\.text)
                + result.actionItems.map(\.task)
                + result.openQuestions.map(\.text))
                .joined(separator: " ")
            tags = result.tags.joined(separator: " ")
        }

        try db.execute(sql: "DELETE FROM recordingSearch WHERE recordingID = ?", arguments: [recordingID.uuidString])
        try db.execute(
            sql: """
                INSERT INTO recordingSearch (recordingID, title, transcriptText, speakerNames, notesText, tags)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [recordingID.uuidString, recording.title, transcriptText, speakerNames, notesText, tags])
    }

    private func write<T: Sendable>(_ updates: @escaping @Sendable (Database) throws -> T) async throws -> T {
        do {
            return try await dbManager.dbQueue.write(updates)
        } catch let error as MaikuError {
            throw error
        } catch {
            throw MaikuError.databaseFailure(error.localizedDescription)
        }
    }

    private func read<T: Sendable>(_ value: @escaping @Sendable (Database) throws -> T) async throws -> T {
        do {
            return try await dbManager.dbQueue.read(value)
        } catch let error as MaikuError {
            throw error
        } catch {
            throw MaikuError.databaseFailure(error.localizedDescription)
        }
    }
}
