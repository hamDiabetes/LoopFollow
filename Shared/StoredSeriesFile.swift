// LoopFollow
// StoredSeriesFile.swift

import Foundation

/// Reading a retained series off disk, with the two ways it can fail kept
/// apart.
///
/// **They call for opposite answers.** Bytes that cannot be fetched at all — a
/// background run reaching a file its data protection class has locked, a
/// container that is not there yet — mean the store's contents are unknown, and
/// an append that writes over them truncates a day of history to one sample.
/// That writer backs off. Bytes that are there and are not this series mean the
/// file will never decode, and a writer that backs off from those blocks every
/// append for the life of the install: the ribbon is empty until the app is
/// reinstalled, and nothing says why.
///
/// So: back off on what cannot be read, replace what cannot be decoded. The
/// version that treated both as unreadable shipped, and the corrupt case was
/// permanent.
enum StoredSeriesFile {
    enum Outcome<T> {
        /// No file yet. The first append starts one.
        case absent

        /// A file that is not this series, which the next write replaces.
        case corrupt

        case present(T)
    }

    /// Throws only where the bytes could not be read. A decode failure comes
    /// back as `.corrupt` rather than as an error, because the caller's answer
    /// to it is to carry on.
    static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> Outcome<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        let data = try Data(contentsOf: url)
        guard let decoded = try? JSONDecoder().decode(type, from: data) else { return .corrupt }
        return .present(decoded)
    }
}
