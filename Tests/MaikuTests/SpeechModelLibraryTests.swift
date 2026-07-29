import Foundation
import Testing

@testable import MaikuKit

// .serialized: every test in this suite points the same
// `SpeechModelLibrary.overrideModelsDirectory` global at a different scratch
// directory, which would race under swift-testing's default parallel
// execution.
@Suite("Speech model library", .serialized)
struct SpeechModelLibraryTests {

    /// Points `SpeechModelLibrary` at a scratch directory populated with
    /// repo-style folder names, restoring the override afterwards so other
    /// tests never see it.
    private func withFakeModelsDirectory(_ folders: [String], _ body: () throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            SpeechModelLibrary.overrideModelsDirectory = nil
        }
        for folder in folders {
            try? FileManager.default.createDirectory(
                at: dir.appending(path: folder), withIntermediateDirectories: true)
        }
        SpeechModelLibrary.overrideModelsDirectory = dir
        try body()
    }

    @Test("No models directory means nothing is reported installed")
    func noDirectoryMeansEmpty() {
        SpeechModelLibrary.overrideModelsDirectory = FileManager.default.temporaryDirectory
            .appending(path: "does-not-exist-\(UUID().uuidString)")
        defer { SpeechModelLibrary.overrideModelsDirectory = nil }
        #expect(SpeechModelLibrary.installedModels().isEmpty)
    }

    @Test("Repo-style folder names map back to plain variant identifiers")
    func installedModelsMapsRepoFolderNames() {
        withFakeModelsDirectory(["openai_whisper-tiny.en", "openai_whisper-large-v3"]) {
            #expect(SpeechModelLibrary.installedModels() == ["tiny.en", "large-v3"])
        }
    }

    @Test("The longest matching variant wins, so small.en is not reported as small")
    func longestMatchWinsOverAShorterPrefix() {
        withFakeModelsDirectory(["openai_whisper-small.en"]) {
            #expect(SpeechModelLibrary.installedModels() == ["small.en"])
        }
    }

    @Test("Deleting a model removes only its own folder")
    func deleteRemovesOnlyItsOwnFolder() throws {
        try withFakeModelsDirectory(["openai_whisper-tiny.en", "openai_whisper-base"]) {
            try SpeechModelLibrary.delete("tiny.en")
            #expect(SpeechModelLibrary.installedModels() == ["base"])
        }
    }

    @Test("Deleting a model that isn't installed is a no-op, not an error")
    func deletingMissingModelIsANoOp() throws {
        try withFakeModelsDirectory(["openai_whisper-base"]) {
            try SpeechModelLibrary.delete("tiny.en")
            #expect(SpeechModelLibrary.installedModels() == ["base"])
        }
    }
}
