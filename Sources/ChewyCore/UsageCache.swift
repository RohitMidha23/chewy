import Foundation

/// Last-known usage per account, persisted across app restarts so the switcher's
/// candidate picker keeps its memory. Contains ONLY usage percentages/reset times —
/// never tokens or credentials — so it is safe to write as a plain (0600) JSON file.
///
/// Staleness: a 5-hour-window reading says nothing once the window it observed has
/// passed, so entries older than `maxAge` (default: the 5-hour horizon) are pruned
/// on load. For an IDLE account a reading within that horizon is a useful prior —
/// its usage can only have gone down (windows reset; idle accounts don't accrue).
public struct UsageCache: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let snapshot: UsageSnapshot
        public let fetchedAt: Date

        public init(snapshot: UsageSnapshot, fetchedAt: Date) {
            self.snapshot = snapshot
            self.fetchedAt = fetchedAt
        }
    }

    /// Default staleness horizon: the 5-hour window length.
    public static let defaultMaxAge: TimeInterval = 5 * 3600

    public var entries: [UUID: Entry]

    public init(entries: [UUID: Entry] = [:]) {
        self.entries = entries
    }

    /// Entries still young enough to be a meaningful prior.
    public func pruned(now: Date, maxAge: TimeInterval = UsageCache.defaultMaxAge) -> UsageCache {
        UsageCache(entries: entries.filter { now.timeIntervalSince($0.value.fetchedAt) <= maxAge })
    }

    /// The snapshots alone, for seeding a live usage map.
    public var snapshotsByAccount: [UUID: UsageSnapshot] {
        entries.mapValues(\.snapshot)
    }

    // MARK: Disk round-trip (atomic, private mode)

    public static func load(from url: URL, now: Date = Date()) -> UsageCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder.iso8601().decode(UsageCache.self, from: data) else {
            return UsageCache()
        }
        return cache.pruned(now: now)
    }

    public func save(to url: URL, fileManager: FileManager = .default) {
        guard let data = try? JSONEncoder.iso8601().encode(self) else { return }
        try? AtomicFileWriter.write(data: data, to: url, fileManager: fileManager)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static func iso8601() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
