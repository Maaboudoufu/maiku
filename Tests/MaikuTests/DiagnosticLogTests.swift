import Foundation
import Testing

@testable import MaikuKit

/// A unique directory per test, removed however the test returns — a log
/// file is not something a failing test should leave behind either.
private func withTemporaryLogDirectory<T>(_ body: (URL) async throws -> T) async rethrows -> T {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "maiku-diagnostic-log-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

@Suite("Diagnostic log")
struct DiagnosticLogTests {

    @Test("A logged line is readable back")
    func readsBackWhatWasLogged() async throws {
        try await withTemporaryLogDirectory { directory in
            let log = DiagnosticLog(directory: directory)
            await log.log("hello world", level: .info)
            let contents = await log.readAll()
            #expect(contents.contains("hello world"))
            #expect(contents.contains("[INFO]"))
        }
    }

    @Test("The log directory is created on first write")
    func createsDirectoryOnFirstWrite() async throws {
        try await withTemporaryLogDirectory { directory in
            let nested = directory.appending(path: "nested")
            let log = DiagnosticLog(directory: nested)
            await log.log("first line")
            #expect(FileManager.default.fileExists(atPath: nested.path))
        }
    }

    @Test("Exceeding the size threshold rotates the file, and old content is preserved")
    func rotatesOnSizeThreshold() async throws {
        try await withTemporaryLogDirectory { directory in
            // A threshold small enough that the very first line already
            // exceeds it, so the second write is guaranteed to rotate.
            let log = DiagnosticLog(directory: directory, maxFileSize: 10, maxRotations: 3)
            await log.log("first entry, well over ten bytes")
            await log.log("second entry")

            let contents = await log.readAll()
            #expect(contents.contains("first entry"))
            #expect(contents.contains("second entry"))
            // Oldest first, so a reader sees history in chronological order.
            let firstRange = try #require(contents.range(of: "first entry"))
            let secondRange = try #require(contents.range(of: "second entry"))
            #expect(firstRange.lowerBound < secondRange.lowerBound)
        }
    }

    @Test("Rotations beyond the configured count are dropped, not accumulated forever")
    func dropsOldestRotationBeyondLimit() async throws {
        try await withTemporaryLogDirectory { directory in
            let log = DiagnosticLog(directory: directory, maxFileSize: 1, maxRotations: 2)
            for index in 1...5 {
                await log.log("entry \(index), padded to exceed the one-byte threshold")
            }
            let contents = await log.readAll()
            // Only the most recent (maxRotations + the live file) survive.
            #expect(!contents.contains("entry 1,"))
            #expect(contents.contains("entry 5,"))
        }
    }
}

@Suite("Diagnostics exporter")
struct DiagnosticsExporterTests {

    @Test("Recording titles are redacted by default; status and errors are not")
    func redactsTitlesByDefault() {
        var recording = Recording(title: "Confidential call with a client", status: .failed)
        recording.errorStage = "finalTranscription"
        recording.errorMessage = "The speech model failed to load."

        let report = DiagnosticsExporter.export(recordings: [recording], logContents: "")

        #expect(!report.contains("Confidential call with a client"))
        #expect(report.contains(recording.id.uuidString))
        #expect(report.contains("status=failed"))
        #expect(report.contains("errorStage=finalTranscription"))
        #expect(report.contains("The speech model failed to load."))
    }

    @Test("Titles are included only when explicitly requested")
    func includesTitlesWhenRequested() {
        let recording = Recording(title: "Weekly sync", status: .complete)
        let report = DiagnosticsExporter.export(
            recordings: [recording], logContents: "", includeTranscripts: true)
        #expect(report.contains("Weekly sync"))
    }

    @Test("Log contents pass through verbatim")
    func includesLogContents() {
        let report = DiagnosticsExporter.export(
            recordings: [], logContents: "2026-01-01T00:00:00Z [ERROR] something broke")
        #expect(report.contains("something broke"))
    }
}
