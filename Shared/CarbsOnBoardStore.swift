// LoopFollow
// CarbsOnBoardStore.swift

import Foundation

/// Persists the carbs-on-board series into the App Group container so the
/// widget can draw the purple ribbon without asking Nightscout for it.
///
/// The app already receives every figure the loop publishes and keeps only the
/// newest, so the series is retained here rather than fetched. What it replaces
/// was a devicestatus history request on every widget refresh: those records
/// carry the whole forecast, which is kilobytes each, for one integer apiece.
///
/// **Safe for two writers.** The app appends on its poll and the widget appends
/// on its timeline run, so writes are coordinated across processes and an append
/// merges into the file as it stands rather than replacing it with a snapshot.
/// A store safe for one writer and a store safe for two are different objects,
/// and the difference is not visible from the call site.
final class CarbsOnBoardStore {
    static let shared = CarbsOnBoardStore()
    private init() {}

    /// Samples older than this are dropped on write. Matches the glucose
    /// series' window, since the two are drawn on the same chart and the ribbon
    /// can only cover what is stored.
    static let window: TimeInterval = GlucoseChartSeriesStore.window

    private let fileName = "carbs_on_board.json"
    private let queue = DispatchQueue(label: "com.loopfollow.carbsOnBoardStore", qos: .utility)

    // MARK: - Public API

    /// Adds one cycle's figure, prunes to the window and writes.
    ///
    /// `completion` carries whether the file changed. The app polls device
    /// status far more often than the loop publishes one, so most calls are a
    /// restatement of the newest sample; a caller that reloads the widget on
    /// every one of them would spend the refresh budget saying nothing.
    ///
    /// Samples at or before the newest stored one are dropped rather than
    /// merged. Out-of-order arrivals here would be a record the loop republished
    /// under an older cycle stamp, and the series it belongs to is already held.
    func append(_ sample: CarbsOnBoardSample, completion: ((Bool) -> Void)? = nil) {
        queue.async {
            var changed = false
            defer { completion?(changed) }
            guard let url = try? self.fileURL() else { return }

            // Coordinated, because the app and the widget are two processes and
            // this queue only orders one of them. The read happens inside the
            // coordinated block rather than before it, so what is merged into is
            // the file as it stands and not a snapshot taken earlier.
            // A coordination failure means the block never ran, so `changed`
            // stays false and the caller does not reload for a write that did
            // not happen.
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { current in
                // A store that cannot be read is left alone. Writing this one
                // sample over it would truncate the history to a point and look
                // exactly like the sparse store this writer exists to prevent.
                let stored: CarbsOnBoardHistory?
                do {
                    switch try StoredSeriesFile.read(CarbsOnBoardHistory.self, at: current) {
                    case .absent: stored = nil
                    // Replaced rather than backed off from. A file that is not
                    // this series will not become one, and a writer that waits
                    // for it waits for the life of the install.
                    case .corrupt: stored = nil
                    case let .present(history): stored = history
                    }
                } catch {
                    return
                }
                guard let merged = OnBoardMerge.merging(stored?.samples ?? [], with: sample) else { return }
                let history = CarbsOnBoardHistory(
                    samples: self.pruned(merged),
                    updatedAt: merged.last?.date ?? sample.date
                )
                changed = self.write(history, to: current)
            }
            if coordinationError != nil { changed = false }
        }
    }

    func load() -> CarbsOnBoardHistory? {
        read()
    }

    /// Removes the stored series. A site that has stopped publishing carbs on
    /// board has to take the ribbon off the chart with it rather than leave the
    /// last figure standing, and an emptied store reads as unknown rather than
    /// as nothing on board.
    func clear(completion: (() -> Void)? = nil) {
        queue.async {
            defer { completion?() }
            guard let url = try? self.fileURL() else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    private func pruned(_ samples: [CarbsOnBoardSample]) -> [CarbsOnBoardSample] {
        let cutoff = Date().addingTimeInterval(-Self.window)
        return samples.filter { $0.date >= cutoff }
    }

    private func read() -> CarbsOnBoardHistory? {
        guard let url = try? fileURL() else { return nil }
        return read(at: url)
    }

    private func read(at url: URL) -> CarbsOnBoardHistory? {
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }

            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(CarbsOnBoardHistory.self, from: data)
        } catch {
            // Intentionally silent (extension-safe, no dependencies).
            return nil
        }
    }

    private func write(_ history: CarbsOnBoardHistory, to url: URL) -> Bool {
        do {
            let data = try JSONEncoder().encode(history)
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            // Intentionally silent (extension-safe, no dependencies).
            return false
        }
    }

    private func fileURL() throws -> URL {
        let groupID = AppGroupID.current()
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw NSError(
                domain: "CarbsOnBoardStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "App Group containerURL is nil for id=\(groupID)"],
            )
        }
        return containerURL.appendingPathComponent(fileName, isDirectory: false)
    }
}
