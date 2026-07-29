import Foundation
import GRDB

/// The `appSettings` row. See the migration comment in `Migrations.swift`.
private struct AppSettingsRow: FetchableRecord, EncodableRecord, PersistableRecord {
    static let databaseTableName = "appSettings"

    var settings: AppSettings
    var updatedAt: Date

    init(settings: AppSettings, updatedAt: Date) {
        self.settings = settings
        self.updatedAt = updatedAt
    }

    init(row: Row) throws {
        let urlText: String = row["lmStudioBaseURL"]
        guard let baseURL = URL(string: urlText) else {
            throw MaikuError.databaseFailure("Malformed row in \(Self.databaseTableName).")
        }
        settings = AppSettings(
            inputDeviceUID: row["inputDeviceUID"],
            speechModelName: row["speechModelName"],
            language: row["language"],
            liveDiarizationEnabled: row["liveDiarizationEnabled"],
            lmStudioBaseURL: baseURL,
            lmStudioModelID: row["lmStudioModelID"],
            lmStudioTimeout: row["lmStudioTimeout"],
            audioRetentionDays: row["audioRetentionDays"],
            reducedMotionOverride: row["reducedMotionOverride"],
            soundEffectsEnabled: row["soundEffectsEnabled"],
            crtEffectsEnabled: row["crtEffectsEnabled"])
        updatedAt = row["updatedAt"]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = 1
        container["inputDeviceUID"] = settings.inputDeviceUID
        container["speechModelName"] = settings.speechModelName
        container["language"] = settings.language
        container["liveDiarizationEnabled"] = settings.liveDiarizationEnabled
        container["lmStudioBaseURL"] = settings.lmStudioBaseURL.absoluteString
        container["lmStudioModelID"] = settings.lmStudioModelID
        container["lmStudioTimeout"] = settings.lmStudioTimeout
        container["audioRetentionDays"] = settings.audioRetentionDays
        container["reducedMotionOverride"] = settings.reducedMotionOverride
        container["soundEffectsEnabled"] = settings.soundEffectsEnabled
        container["crtEffectsEnabled"] = settings.crtEffectsEnabled
        container["updatedAt"] = updatedAt
    }
}

/// Reads and writes the one `appSettings` row. Returns `AppSettings()`
/// defaults when no row has been saved yet, so first launch needs no
/// separate "has the user configured anything" check.
public struct SettingsStore: Sendable {
    private let dbManager: DatabaseManager

    public init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    public func fetch() async throws -> AppSettings {
        try await read { db in
            try AppSettingsRow.fetchOne(db, key: 1)?.settings ?? AppSettings()
        }
    }

    public func save(_ settings: AppSettings) async throws {
        try await write { db in
            try AppSettingsRow(settings: settings, updatedAt: Date()).save(db)
        }
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
