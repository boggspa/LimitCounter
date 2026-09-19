import Foundation

/// Per-file cache of parsed telemetry, so a refresh only pays to parse files
/// that actually changed.
///
/// Provider scans re-read the same session logs on every refresh. Those files
/// are append-only and mostly cold, so parsing them repeatedly is the dominant
/// cost of a scan and the reason byte/file caps had to be set low enough to
/// hurt accuracy. Keying on `(provider, path, modifiedAt, size)` makes a
/// repeat scan near-free and lets those caps be set for correctness instead.
///
/// - Entries are opaque `Data` payloads: each provider encodes its own record
///   type, so one cache serves all of them.
/// - The on-disk format is JSONL (header line + one line per file) so load and
///   persist stream line-by-line rather than materializing one giant object.
/// - All disk IO is best-effort. A missing or corrupt cache simply means a
///   full re-parse, never a wrong or missing usage surface.
///
/// **Bump `formatVersion` whenever a provider's parse output changes shape or
/// semantics.** Entries are keyed on file identity alone, so an unchanged file
/// would otherwise keep serving the previous parser's records indefinitely.
public final class TelemetryParseCache: @unchecked Sendable {
    /// v2: Codex records require usage or recognised task activity; metadata and
    /// repeated token-count notifications no longer produce activity markers.
    private static let formatVersion = 2

    public static let shared = TelemetryParseCache(filename: "telemetry-parse-cache.jsonl")

    private struct Entry: Codable {
        let provider: String
        let path: String
        let modifiedAt: Double
        let size: Int
        let payload: Data

        enum CodingKeys: String, CodingKey {
            case provider = "p"
            case path = "f"
            case modifiedAt = "m"
            case size = "s"
            case payload = "d"
        }
    }

    private struct Header: Codable {
        let version: Int
    }

    private let filename: String
    private let directoryOverride: URL?
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var dirty = false

    public init(filename: String, directory: URL? = nil) {
        self.filename = filename
        self.directoryOverride = directory
    }

    // MARK: - Lookup

    /// Returns the cached payload for a file, or nil when it is absent or the
    /// file has changed since it was cached.
    public func payload(provider: String, path: String, modifiedAt: Date, size: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        guard let entry = entries[cacheKey(provider: provider, path: path)] else { return nil }
        guard entry.size == size,
              abs(entry.modifiedAt - modifiedAt.timeIntervalSince1970) < 0.000_001 else {
            return nil
        }
        return entry.payload
    }

    public func store(provider: String, path: String, modifiedAt: Date, size: Int, payload: Data) {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        entries[cacheKey(provider: provider, path: path)] = Entry(
            provider: provider,
            path: path,
            modifiedAt: modifiedAt.timeIntervalSince1970,
            size: size,
            payload: payload
        )
        dirty = true
    }

    /// Drops entries whose file has vanished, then bounds the store to the
    /// newest `keepingNewest` files for that provider.
    ///
    /// Deliberately NOT keyed on "files in the current scan": a scan's file
    /// list shifts between refreshes (backfill walks different missing dates
    /// each time), so pruning against it would evict entries the next refresh
    /// still wants. The size bound targets the repeatedly-scanned working set —
    /// historical files are read once by backfill and then never again, so
    /// retaining them costs disk for no hit-rate.
    public func prune(provider: String, keepingNewest maxEntries: Int) {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()

        let manager = FileManager.default
        var mine = entries.filter { $0.value.provider == provider }
        var removed = false

        for (key, entry) in mine where !manager.fileExists(atPath: entry.path) {
            entries.removeValue(forKey: key)
            mine.removeValue(forKey: key)
            removed = true
        }

        if mine.count > maxEntries {
            let doomed = mine
                .sorted { $0.value.modifiedAt > $1.value.modifiedAt }
                .dropFirst(maxEntries)
            for (key, _) in doomed {
                entries.removeValue(forKey: key)
                removed = true
            }
        }

        if removed { dirty = true }
    }

    /// Writes the cache out when anything changed. Cheap no-op otherwise, so
    /// a steady-state refresh that parsed nothing also writes nothing.
    public func persist() {
        lock.lock()
        defer { lock.unlock() }
        guard dirty, let url = cacheFileURL() else { return }

        var text = ""
        if let header = try? JSONEncoder().encode(Header(version: Self.formatVersion)),
           let headerLine = String(data: header, encoding: .utf8) {
            text += headerLine + "\n"
        }
        let encoder = JSONEncoder()
        for entry in entries.values {
            guard let data = try? encoder.encode(entry),
                  let line = String(data: data, encoding: .utf8) else { continue }
            text += line + "\n"
        }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? text.write(to: url, atomically: true, encoding: .utf8)
        dirty = false
    }

    // MARK: - Disk

    private func cacheKey(provider: String, path: String) -> String {
        "\(provider)\u{1}\(path)"
    }

    private func loadIfNeededLocked() {
        guard !loaded else { return }
        loaded = true

        guard let url = cacheFileURL(),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }

        let decoder = JSONDecoder()
        var sawValidHeader = false
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8) else { continue }
            if !sawValidHeader {
                // A cache written by a previous parser is discarded wholesale.
                guard let header = try? decoder.decode(Header.self, from: data),
                      header.version == Self.formatVersion else {
                    entries.removeAll()
                    return
                }
                sawValidHeader = true
                continue
            }
            guard let entry = try? decoder.decode(Entry.self, from: data) else { continue }
            entries[cacheKey(provider: entry.provider, path: entry.path)] = entry
        }
    }

    private func cacheFileURL() -> URL? {
        if let directoryOverride {
            return directoryOverride.appendingPathComponent(filename)
        }
        let manager = FileManager.default
        if let container = manager.containerURL(
            forSecurityApplicationGroupIdentifier: UsageRefreshCadence.appGroupID
        ) {
            return container.appendingPathComponent(filename)
        }
        guard let caches = try? manager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        return caches
            .appendingPathComponent("LLMUsageCounter", isDirectory: true)
            .appendingPathComponent(filename)
    }
}
