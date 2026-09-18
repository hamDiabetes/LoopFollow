// LoopFollow
// StoredSeriesFileTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// The two failures a stored series can have, which the appending writers act
/// on in opposite directions.
struct StoredSeriesFileTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stored-series-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func noFileIsAbsent() throws {
        let url = try temporaryDirectory().appendingPathComponent("none.json")
        guard case .absent = try StoredSeriesFile.read(CarbsOnBoardHistory.self, at: url) else {
            Issue.record("expected absent")
            return
        }
    }

    @Test func aStoredSeriesComesBack() throws {
        let url = try temporaryDirectory().appendingPathComponent("series.json")
        let history = CarbsOnBoardHistory(
            samples: [CarbsOnBoardSample(date: Date(timeIntervalSince1970: 1_757_000_000), grams: 12)],
            updatedAt: Date(timeIntervalSince1970: 1_757_000_000)
        )
        try JSONEncoder().encode(history).write(to: url)

        guard case let .present(read) = try StoredSeriesFile.read(CarbsOnBoardHistory.self, at: url) else {
            Issue.record("expected present")
            return
        }
        #expect(read.samples.count == 1)
        #expect(read.samples[0].grams == 12)
    }

    /// Bytes that are not this series will never become it. Treating them as
    /// unreadable — which is what shipped — blocked every append for the life of
    /// the install, and the ribbon stayed empty until a reinstall.
    @Test func gibberishIsCorruptRatherThanUnreadable() throws {
        let url = try temporaryDirectory().appendingPathComponent("corrupt.json")
        try Data("not json at all".utf8).write(to: url)

        guard case .corrupt = try StoredSeriesFile.read(CarbsOnBoardHistory.self, at: url) else {
            Issue.record("expected corrupt")
            return
        }
    }

    /// JSON that parses but is a different shape counts as corrupt too: a store
    /// written by some other version is no more decodable than gibberish.
    @Test func theWrongShapeIsCorruptToo() throws {
        let url = try temporaryDirectory().appendingPathComponent("wrong.json")
        try Data(#"{"hello":"world"}"#.utf8).write(to: url)

        guard case .corrupt = try StoredSeriesFile.read(CarbsOnBoardHistory.self, at: url) else {
            Issue.record("expected corrupt")
            return
        }
    }

    /// End to end: a store that has been corrupted takes the next append.
    ///
    /// The unit above states the rule; this is the behaviour Justin would see —
    /// the ribbon coming back on its own rather than after a reinstall.
    @Test func aCorruptStoreRecoversOnTheNextAppend() async throws {
        let group = AppGroupID.current()
        let container = try #require(
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
            "no App Group container: \(group)"
        )
        let url = container.appendingPathComponent("carbs_on_board.json", isDirectory: false)
        let saved = try? Data(contentsOf: url)
        defer {
            if let saved { try? saved.write(to: url) } else { try? FileManager.default.removeItem(at: url) }
        }

        try Data("not json at all".utf8).write(to: url)
        #expect(CarbsOnBoardStore.shared.load() == nil)

        let sample = CarbsOnBoardSample(date: Date(), grams: 9)
        await withCheckedContinuation { continuation in
            CarbsOnBoardStore.shared.append(sample) { _ in continuation.resume() }
        }

        let recovered = try #require(CarbsOnBoardStore.shared.load())
        #expect(recovered.samples.last?.grams == 9)
    }

    /// Bytes that cannot be fetched are the case the writer must back off from,
    /// and they still throw. A directory where a file is expected stands in for
    /// the real one, which is a background run reaching a file its data
    /// protection class has locked.
    @Test func whatCannotBeReadStillThrows() throws {
        let url = try temporaryDirectory().appendingPathComponent("blocked.json", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) {
            try StoredSeriesFile.read(CarbsOnBoardHistory.self, at: url)
        }
    }
}
