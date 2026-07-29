import Foundation
import GRDB

/// Owns the single `DatabaseQueue` maiku reads and writes through.
///
/// Foreign keys are on by default in GRDB's `Configuration` (plan §8), so
/// there is nothing to flip here — a deliberately-empty check for that would
/// just be a comment pretending to be code.
public final class DatabaseManager: Sendable {

    public let dbQueue: DatabaseQueue

    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Migrations.migrator().migrate(dbQueue)
    }

    /// Opens (creating if needed) the database at `AppPaths.databaseURL`.
    public static func openStandard() throws -> DatabaseManager {
        do {
            try AppPaths.ensureDirectoriesExist()
            let queue = try DatabaseQueue(path: AppPaths.databaseURL.path)
            return try DatabaseManager(dbQueue: queue)
        } catch {
            throw MaikuError.databaseFailure(error.localizedDescription)
        }
    }

    /// An ephemeral database for tests and previews — same schema, no disk.
    public static func openInMemory() throws -> DatabaseManager {
        do {
            let queue = try DatabaseQueue()
            return try DatabaseManager(dbQueue: queue)
        } catch {
            throw MaikuError.databaseFailure(error.localizedDescription)
        }
    }
}
