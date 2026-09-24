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
/// - Each provider stores its own `Codable` record type, so one cache serves
///   all of them. A payload is decoded at most once per process and the
///   decoded value stays in memory, so an unchanged file costs a dictionary
///   lookup on every later refresh rather than a JSON decode.
/// - On disk the cache is JSONL: a header line, then one
///   `identity<TAB>payload` line per file. `persist()` appends lines for the
///   files that changed, plus tombstones for evicted ones, and rewrites the
///   file only once superseded lines outweigh live ones. Rewriting the whole
///   store on every refresh cost more than the parsing it saved.
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

    /// The appendable line layout. It lives in its own file so an older build
    /// running alongside (a debug build next to the installed one) keeps its
    /// own whole-file cache instead of discarding this one on every refresh.
    private static let layoutVersion = 2

    /// The app's cache, in its App Group container. An unbundled process —
    /// one of the swiftc test runners — gets a private temporary directory
    /// instead, so a test that falls back to real session logs can never
    /// rewrite the running app's cache.
    public static let shared: TelemetryParseCache = {
        guard Bundle.main.bundleIdentifier != nil else {
            return TelemetryParseCache(
                filename: "telemetry-parse-cache-2.jsonl",
                directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "limit-counter-parse-cache-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
            )
        }
        return TelemetryParseCache(
            filename: "telemetry-parse-cache-2.jsonl",
            legacyFilename: "telemetry-parse-cache.jsonl"
        )
    }()

    private static let tab: UInt8 = 0x09
    private static let newline: UInt8 = 0x0A

    private struct Key: Hashable {
        let provider: String
        let path: String
    }

    private struct FileHeader: Codable {
        let version: Int
        let layout: Int?
    }

    /// The part of a line before the tab. A tombstone has no tab and no
    /// identity: it records that the file's entry was evicted.
    private struct LineIdentity: Codable {
        let provider: String
        let path: String
        let modifiedAt: Double?
        let size: Int?

        enum CodingKeys: String, CodingKey {
            case provider = "p"
            case path = "f"
            case modifiedAt = "m"
            case size = "s"
        }
    }

    /// One line of the whole-file layout that preceded layout 2.
    private struct LegacyEntry: Decodable {
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

    private struct Entry {
        let modifiedAt: Double
        let size: Int
        /// The encoded identity, kept so neither an append nor a rewrite
        /// re-encodes anything.
        let identity: Data
        /// The records as JSON, exactly as written after the tab.
        let payload: Data
        /// The decoded records, filled on first lookup.
        var decoded: Any?

        var lineByteCount: Int { identity.count + payload.count + 2 }

        func matches(modifiedAt: Date, size: Int) -> Bool {
            self.size == size && abs(self.modifiedAt - modifiedAt.timeIntervalSince1970) < 0.000_001
        }
    }

    private let filename: String
    private let legacyFilename: String?
    private let directoryOverride: URL?
    /// Superseded lines may grow the file by this much, or by its live size
    /// when that is larger, before `persist()` rewrites it compactly.
    private let minimumCompactionSlack: Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var loaded = false
    /// Files stored or evicted since the file on disk last reflected them.
    private var unsavedKeys: Set<Key> = []
    /// The file on disk is in the current layout and still exactly as this
    /// cache last left it, so changes can be appended to it.
    private var appendable = false
    /// Rewrite at the next persist even with nothing unsaved: the file is
    /// legacy, torn, or mostly superseded lines.
    private var wantsRewrite = false
    /// Entries were imported from the legacy file, which goes once the
    /// current file has been written.
    private var importedLegacyFile = false
    /// Size of the file as this cache last left it.
    private var fileByteCount = 0
    /// Size of the entry lines a rewrite would produce.
    private var liveByteCount = 0

    public init(
        filename: String,
        directory: URL? = nil,
        legacyFilename: String? = nil,
        minimumCompactionSlack: Int = 16 * 1_024 * 1_024
    ) {
        self.filename = filename
        self.legacyFilename = legacyFilename
        self.directoryOverride = directory
        self.minimumCompactionSlack = minimumCompactionSlack
    }

    // MARK: - Lookup

    /// The cached records of a file, or nil when they are absent, the file
    /// has changed since it was cached, or they were cached as another type.
    ///
    /// The payload is decoded once; later lookups of the unchanged file
    /// return the same in-memory value.
    public func value<Value: Decodable>(
        _ type: Value.Type,
        provider: String,
        path: String,
        modifiedAt: Date,
        size: Int
    ) -> Value? {
        let key = Key(provider: provider, path: path)
        lock.lock()
        loadIfNeededLocked()
        guard let entry = entries[key], entry.matches(modifiedAt: modifiedAt, size: size) else {
            lock.unlock()
            return nil
        }
        if let decoded = entry.decoded as? Value {
            lock.unlock()
            return decoded
        }
        let payload = entry.payload
        lock.unlock()

        // Decoded outside the lock so one large payload does not stall
        // another provider's concurrent scan.
        guard let value = try? JSONDecoder().decode(Value.self, from: payload) else { return nil }
        lock.lock()
        if entries[key]?.payload == payload {
            entries[key]?.decoded = value
        }
        lock.unlock()
        return value
    }

    public func store<Value: Encodable>(
        _ value: Value,
        provider: String,
        path: String,
        modifiedAt: Date,
        size: Int
    ) {
        guard let payload = try? JSONEncoder().encode(value),
              // Each entry must stay on one line. JSONEncoder never emits a
              // raw newline without `.prettyPrinted`; this only guards that.
              !payload.contains(Self.newline),
              let identity = Self.encodedIdentity(
                provider: provider,
                path: path,
                modifiedAt: modifiedAt.timeIntervalSince1970,
                size: size
              ) else {
            return
        }

        let key = Key(provider: provider, path: path)
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        if let previous = entries[key] {
            liveByteCount -= previous.lineByteCount
        }
        let entry = Entry(
            modifiedAt: modifiedAt.timeIntervalSince1970,
            size: size,
            identity: identity,
            payload: payload,
            decoded: value
        )
        entries[key] = entry
        liveByteCount += entry.lineByteCount
        unsavedKeys.insert(key)
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
        var mine = entries.filter { $0.key.provider == provider }

        for key in mine.keys where !manager.fileExists(atPath: key.path) {
            removeLocked(key)
            mine.removeValue(forKey: key)
        }

        if mine.count > maxEntries {
            let doomed = mine
                .sorted { $0.value.modifiedAt > $1.value.modifiedAt }
                .dropFirst(maxEntries)
            for (key, _) in doomed {
                removeLocked(key)
            }
        }
    }

    /// Records the changes since the last call. Cheap no-op when nothing
    /// changed, so a steady-state refresh that parsed nothing writes nothing;
    /// otherwise it appends only the changed files' lines.
    public func persist() {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        guard !unsavedKeys.isEmpty || wantsRewrite, let url = cacheFileURL() else { return }

        if appendable, !wantsRewrite, fileByteCount(at: url) == fileByteCount {
            var appended = Data()
            for key in unsavedKeys {
                if let entry = entries[key] {
                    appendLine(for: entry, to: &appended)
                } else if let tombstone = Self.encodedIdentity(
                    provider: key.provider,
                    path: key.path,
                    modifiedAt: nil,
                    size: nil
                ) {
                    appended.append(tombstone)
                    appended.append(Self.newline)
                }
            }
            let grownByteCount = fileByteCount + appended.count
            let supersededByteCount = grownByteCount - liveByteCount
            if supersededByteCount <= max(liveByteCount, minimumCompactionSlack),
               append(appended, to: url) {
                fileByteCount = grownByteCount
                unsavedKeys.removeAll()
                return
            }
        }

        rewrite(to: url)
    }

    // MARK: - Disk

    private static func encodedIdentity(
        provider: String,
        path: String,
        modifiedAt: Double?,
        size: Int?
    ) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try? encoder.encode(
            LineIdentity(provider: provider, path: path, modifiedAt: modifiedAt, size: size)
        )
    }

    private func removeLocked(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        liveByteCount -= entry.lineByteCount
        unsavedKeys.insert(key)
    }

    private func appendLine(for entry: Entry, to data: inout Data) {
        data.append(entry.identity)
        data.append(Self.tab)
        data.append(entry.payload)
        data.append(Self.newline)
    }

    /// Appends with `O_APPEND`, so a write can never land on top of another
    /// writer's line, only after it.
    private func append(_ data: Data, to url: URL) -> Bool {
        let descriptor = open(url.path, O_WRONLY | O_APPEND)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let complete = data.withUnsafeBytes { buffer -> Bool in
            guard var next = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(descriptor, next, remaining)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                next += written
                remaining -= written
            }
            return true
        }
        // A partial append leaves a torn line; only a rewrite recovers.
        if !complete { appendable = false }
        return complete
    }

    private func rewrite(to url: URL) {
        var data = Data(capacity: max(0, liveByteCount) + 64)
        if let header = try? JSONEncoder().encode(
            FileHeader(version: Self.formatVersion, layout: Self.layoutVersion)
        ) {
            data.append(header)
            data.append(Self.newline)
        }
        for entry in entries.values {
            appendLine(for: entry, to: &data)
        }

        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: url, options: .atomic)
            fileByteCount = data.count
            appendable = true
            if importedLegacyFile, let legacyURL = cacheFileURL(named: legacyFilename) {
                try? manager.removeItem(at: legacyURL)
                importedLegacyFile = false
            }
        } catch {
            appendable = false
        }
        // Like a failed append, a failed write is not retried until something
        // else changes, so a full disk cannot turn every refresh into a rewrite.
        unsavedKeys.removeAll()
        wantsRewrite = false
    }

    private func fileByteCount(at url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    private func loadIfNeededLocked() {
        guard !loaded else { return }
        loaded = true

        if let url = cacheFileURL(),
           let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            load(data)
        } else if let legacyURL = cacheFileURL(named: legacyFilename),
                  let data = try? Data(contentsOf: legacyURL, options: .mappedIfSafe) {
            load(data)
            importedLegacyFile = true
            wantsRewrite = !entries.isEmpty
        }
    }

    private func load(_ data: Data) {
        let lines = lineRanges(in: data)
        guard let headerRange = lines.first,
              let header = try? JSONDecoder().decode(FileHeader.self, from: data[headerRange]),
              // A cache written by a previous parser is discarded wholesale.
              header.version == Self.formatVersion else {
            return
        }

        let decoder = JSONDecoder()
        let isLegacyLayout = header.layout == nil
        // A crash mid-append leaves the last line torn: skip it, and never
        // append after it.
        let isTorn = data.last != Self.newline
        if isTorn { wantsRewrite = true }
        for range in lines.dropFirst().dropLast(isTorn ? 1 : 0) {
            let line = data[range]
            guard !line.isEmpty else { continue }
            if isLegacyLayout {
                guard let legacy = try? decoder.decode(LegacyEntry.self, from: line) else { continue }
                insertLoadedEntry(
                    key: Key(provider: legacy.provider, path: legacy.path),
                    modifiedAt: legacy.modifiedAt,
                    size: legacy.size,
                    payload: legacy.payload
                )
                continue
            }

            let tabIndex = line.firstIndex(of: Self.tab)
            guard let identity = try? decoder.decode(
                LineIdentity.self,
                from: line[line.startIndex..<(tabIndex ?? line.endIndex)]
            ) else {
                wantsRewrite = true
                continue
            }
            let key = Key(provider: identity.provider, path: identity.path)
            guard let tabIndex, let modifiedAt = identity.modifiedAt, let size = identity.size else {
                // A tombstone: a later line evicted this file's entry.
                if let evicted = entries.removeValue(forKey: key) {
                    liveByteCount -= evicted.lineByteCount
                }
                continue
            }
            insertLoadedEntry(
                key: key,
                modifiedAt: modifiedAt,
                size: size,
                identity: Data(line[line.startIndex..<tabIndex]),
                payload: Data(line[line.index(after: tabIndex)...])
            )
        }

        if isLegacyLayout {
            wantsRewrite = !entries.isEmpty
            return
        }
        fileByteCount = data.count
        appendable = !wantsRewrite
        if data.count - liveByteCount > max(liveByteCount, minimumCompactionSlack) {
            wantsRewrite = true
        }
    }

    private func insertLoadedEntry(
        key: Key,
        modifiedAt: Double,
        size: Int,
        identity: Data? = nil,
        payload: Data
    ) {
        guard let identityData = identity ?? Self.encodedIdentity(
            provider: key.provider,
            path: key.path,
            modifiedAt: modifiedAt,
            size: size
        ) else { return }
        if let previous = entries[key] {
            liveByteCount -= previous.lineByteCount
        }
        let entry = Entry(
            modifiedAt: modifiedAt,
            size: size,
            identity: identityData,
            payload: payload,
            decoded: nil
        )
        entries[key] = entry
        liveByteCount += entry.lineByteCount
    }

    /// Byte ranges of the newline-separated lines, without their newlines. A
    /// trailing newline does not produce an extra empty line.
    private func lineRanges(in data: Data) -> [Range<Data.Index>] {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return [] }
            var ranges: [Range<Data.Index>] = []
            var lineStart = 0
            while lineStart < buffer.count {
                let lineEnd = memchr(base + lineStart, Int32(Self.newline), buffer.count - lineStart)
                    .map { base.distance(to: UnsafeRawPointer($0)) } ?? buffer.count
                ranges.append((data.startIndex + lineStart)..<(data.startIndex + lineEnd))
                lineStart = lineEnd + 1
            }
            return ranges
        }
    }

    private func cacheFileURL() -> URL? {
        cacheFileURL(named: filename)
    }

    private func cacheFileURL(named name: String?) -> URL? {
        guard let name else { return nil }
        if let directoryOverride {
            return directoryOverride.appendingPathComponent(name)
        }
        let manager = FileManager.default
        if let container = manager.containerURL(
            forSecurityApplicationGroupIdentifier: UsageRefreshCadence.appGroupID
        ) {
            return container.appendingPathComponent(name)
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
            .appendingPathComponent(name)
    }
}
