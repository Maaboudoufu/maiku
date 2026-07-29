import Foundation
import GRDB

/// Schema history for the Maiku database. Plan §8: migrations from the first
/// commit, foreign keys on, FTS5 across the searchable fields.
///
/// Column names are camelCase, matching the Swift property names on
/// `Recording`/`Speaker`/`TranscriptSegment` exactly, so their
/// `FetchableRecord`/`EncodableRecord` conformances (see
/// `Repositories/RecordingRepository.swift`) need no column-name mapping
/// layer. Plan §8's field list is otherwise followed as-is.
enum Migrations {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "recordings") { t in
                t.column("id", .text).primaryKey()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("title", .text).notNull()
                t.column("status", .text).notNull()
                t.column("recordingStartedAt", .datetime).notNull()
                t.column("recordingEndedAt", .datetime)
                t.column("durationSeconds", .double).notNull()
                t.column("audioRelativePath", .text)
                t.column("workingAudioRelativePath", .text)
                t.column("transcriptionModel", .text)
                t.column("lmStudioModel", .text)
                t.column("language", .text).notNull()
                t.column("errorStage", .text)
                t.column("errorMessage", .text)
                t.column("processingProgress", .double)
                t.column("trashedAt", .datetime)
            }

            try db.create(table: "speakers") { t in
                t.column("id", .text).primaryKey()
                t.column("recordingID", .text).notNull()
                    .indexed().references("recordings", onDelete: .cascade)
                t.column("diarizerLabel", .text).notNull()
                t.column("customName", .text)
                t.column("colorIndex", .integer).notNull()
            }

            try db.create(table: "transcriptSegments") { t in
                t.column("id", .text).primaryKey()
                t.column("recordingID", .text).notNull()
                    .indexed().references("recordings", onDelete: .cascade)
                t.column("speakerID", .text).references("speakers", onDelete: .setNull)
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("text", .text).notNull()
                t.column("confidence", .double)
                t.column("isFinal", .boolean).notNull()
                t.column("source", .text).notNull()
            }

            // ponytail: one JSON blob per recording rather than the normalised
            // organized_sections/action_items/decisions/quotes/topics tables
            // plan §8 lists. Every milestone so far — including Milestone 5's
            // own bullet list — only ever reads or replaces a whole
            // OrganizedRecording at once (search indexes derived text from
            // it; export reads the whole thing; the M4 notes editor re-saves
            // the whole document), so a blob keeps being the honest shortest
            // path rather than a deferred debt. Upgrade to normalised tables
            // once a real feature needs to edit or delete a single action
            // item without touching the rest.
            try db.create(table: "organizedResults") { t in
                t.column("recordingID", .text).primaryKey()
                    .references("recordings", onDelete: .cascade)
                t.column("json", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // ponytail: a single row per recording, rebuilt wholesale by
            // RecordingRepository whenever its title, transcript, speakers or
            // notes change, rather than SQLite triggers keeping an
            // external-content FTS table in sync automatically. At the scale
            // of "however many recordings one person has", rebuilding one row
            // is unmeasurable; triggers would earn their complexity once
            // partial-column updates on large libraries make that cost real.
            try db.create(virtualTable: "recordingSearch", using: FTS5()) { t in
                t.column("recordingID").notIndexed()
                t.column("title")
                t.column("transcriptText")
                t.column("speakerNames")
                t.column("notesText")
                t.column("tags")
            }
        }

        // Milestone 5: one singleton row of app-wide settings (plan §10.7).
        // The LM Studio API token is deliberately not a column here — it
        // lives in the Keychain per plan §12 and is looked up by
        // `KeychainTokenStore` alongside this row.
        migrator.registerMigration("v2") { db in
            try db.create(table: "appSettings") { t in
                t.column("id", .integer).primaryKey().check { $0 == 1 }
                t.column("inputDeviceUID", .text)
                t.column("speechModelName", .text).notNull()
                t.column("language", .text).notNull()
                t.column("liveDiarizationEnabled", .boolean).notNull()
                t.column("lmStudioBaseURL", .text).notNull()
                t.column("lmStudioModelID", .text)
                t.column("lmStudioTimeout", .double).notNull()
                t.column("audioRetentionDays", .integer)
                t.column("reducedMotionOverride", .boolean)
                t.column("soundEffectsEnabled", .boolean).notNull()
                t.column("crtEffectsEnabled", .boolean).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        return migrator
    }
}
