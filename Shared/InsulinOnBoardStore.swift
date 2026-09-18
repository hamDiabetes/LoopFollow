// LoopFollow
// InsulinOnBoardStore.swift

import Foundation

/// Persists the insulin-on-board series into the App Group container, beside
/// the carb series and on the same terms.
///
/// The figure comes from the same devicestatus record one field over, so the
/// app already receives every one the loop publishes. Retaining them is what
/// lets the blue ribbon draw insulin on board over time rather than marking the
/// moments a dose was given.
///
/// The ribbon's scale is not here and is not the loop's: it is two settings,
/// units at full height and how tall full height is. A figure derived from the
/// loop moved through the day and took the drawn past with it.
///
/// **Safe for two writers**, on the same terms as `CarbsOnBoardStore`.
final class InsulinOnBoardStore {
    static let shared = InsulinOnBoardStore()
    private init() {}

    /// Samples older than this are dropped on write, matching the carb series.
    static let window: TimeInterval = GlucoseChartSeriesStore.window

    private let fileName = "insulin_on_board.json"
    private let queue = DispatchQueue(label: "com.loopfollow.insulinOnBoardStore", qos: .utility)

    // MARK: - Public API

    /// Adds one cycle's figure, prunes to the window and writes.
    ///
    /// `completion` carries whether the file changed. The app polls device
    /// status far more often than the loop publishes one, so most calls are a
    /// restatement of the newest sample; a caller that reloads the widget on
    /// every one of them would spend the refresh budget saying nothing.
    ///
    /// A sample whose cycle is already held is dropped; one from before the
    /// newest is merged into place. Records reach the app out of order — the
    /// poll's window is read newest first — and the series is kept in cycle
    /// order regardless of arrival order.
    func append(_ sample: InsulinOnBoardSample, completion: ((Bool) -> Void)? = nil) {
        append(contentsOf: [sample], completion: completion)
    }

    /// Adds a window of cycles in one write.
    ///
    /// The poll asks for every record since the newest sample held, so the first
    /// one after the app has been closed carries hours of them. One merge and
    /// one write, because this file is coordinated across two processes and the
    /// per-sample cost is the coordination rather than the arithmetic.
    func append(contentsOf samples: [InsulinOnBoardSample], completion: ((Bool) -> Void)? = nil) {
        guard !samples.isEmpty else {
            completion?(false)
            return
        }

        queue.async {
            var changed = false
            defer { completion?(changed) }
            guard let url = try? self.fileURL() else { return }

            // Coordinated and merged, for the reason on `CarbsOnBoardStore`:
            // the app and the widget both write this file now.
            // A coordination failure means the block never ran, so `changed`
            // stays false and the caller does not reload for a write that did
            // not happen.
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { current in
                // A store that cannot be read is left alone. Writing this one
                // sample over it would truncate the history to a point and look
                // exactly like the sparse store this writer exists to prevent.
                let stored: InsulinOnBoardHistory?
                do {
                    switch try StoredSeriesFile.read(InsulinOnBoardHistory.self, at: current) {
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
                guard let merged = OnBoardMerge.merging(stored?.samples ?? [], with: samples) else { return }
                let history = InsulinOnBoardHistory(
                    samples: self.pruned(merged),
                    updatedAt: merged.last?.date ?? samples[samples.count - 1].date
                )
                changed = self.write(history, to: current)
            }
            if coordinationError != nil { changed = false }
        }
    }

    func load() -> InsulinOnBoardHistory? {
        read()
    }

    /// Removes the stored series, which reads as unknown rather than as no
    /// insulin acting.
    func clear(completion: (() -> Void)? = nil) {
        queue.async {
            defer { completion?() }
            guard let url = try? self.fileURL() else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    private func pruned(_ samples: [InsulinOnBoardSample]) -> [InsulinOnBoardSample] {
        let cutoff = Date().addingTimeInterval(-Self.window)
        return samples.filter { $0.date >= cutoff }
    }

    private func read() -> InsulinOnBoardHistory? {
        guard let url = try? fileURL() else { return nil }
        return read(at: url)
    }

    private func read(at url: URL) -> InsulinOnBoardHistory? {
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }

            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(InsulinOnBoardHistory.self, from: data)
        } catch {
            // Intentionally silent (extension-safe, no dependencies).
            return nil
        }
    }

    private func write(_ history: InsulinOnBoardHistory, to url: URL) -> Bool {
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
                domain: "InsulinOnBoardStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "App Group containerURL is nil for id=\(groupID)"],
            )
        }
        return containerURL.appendingPathComponent(fileName, isDirectory: false)
    }
}
