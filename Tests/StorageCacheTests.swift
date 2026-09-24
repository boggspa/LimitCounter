import Foundation

private enum TestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message):
            return message
        }
    }
}

private func expect(_ condition: Bool, _ label: String) throws {
    guard condition else {
        throw TestError.failure(label)
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
    guard actual == expected else {
        throw TestError.failure("\(label): expected \(expected), got \(actual)")
    }
}

private func makeTempRoot(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("storage-cache-tests-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func fileSize(_ url: URL) throws -> Int {
    try (FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        ?? { throw TestError.failure("no size for \(url.lastPathComponent)") }()
}

private func lines(of url: URL) throws -> [String] {
    try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
}

/// Counts decodes, to show an unchanged file's payload is decoded only once.
private struct CountedRecords: Codable, Equatable {
    nonisolated(unsafe) static var decodeCount = 0

    let values: [Int]

    init(values: [Int]) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        Self.decodeCount += 1
        values = try [Int](from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try values.encode(to: encoder)
    }
}

private let modifiedAt = Date(timeIntervalSince1970: 1_790_000_000.123456)

// MARK: - TelemetryParseCache

private func testUnchangedFilesAreServedAcrossInstances() throws {
    let root = try makeTempRoot("reload")
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = TelemetryParseCache(filename: "cache.jsonl", directory: root)
    writer.store([1, 2, 3], provider: "p", path: "/a.jsonl", modifiedAt: modifiedAt, size: 10)
    writer.store(["x"], provider: "q", path: "/b.jsonl", modifiedAt: modifiedAt, size: 20)
    writer.persist()

    let reader = TelemetryParseCache(filename: "cache.jsonl", directory: root)
    try expectEqual(
        reader.value([Int].self, provider: "p", path: "/a.jsonl", modifiedAt: modifiedAt, size: 10),
        [1, 2, 3],
        "an unchanged file is served from disk by a new instance"
    )
    try expectEqual(
        reader.value([String].self, provider: "q", path: "/b.jsonl", modifiedAt: modifiedAt, size: 20),
        ["x"],
        "entries are kept per provider"
    )
    try expect(
        reader.value([Int].self, provider: "p", path: "/a.jsonl", modifiedAt: modifiedAt, size: 11) == nil,
        "a file whose size changed is re-parsed"
    )
    try expect(
        reader.value(
            [Int].self,
            provider: "p",
            path: "/a.jsonl",
            modifiedAt: modifiedAt.addingTimeInterval(1),
            size: 10
        ) == nil,
        "a file whose modification date changed is re-parsed"
    )
    try expect(
        reader.value([Int].self, provider: "q", path: "/a.jsonl", modifiedAt: modifiedAt, size: 10) == nil,
        "another provider's entry for the same path is not served"
    )
}

private func testPersistAppendsOnlyChangedEntries() throws {
    let root = try makeTempRoot("append")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("cache.jsonl")

    let cache = TelemetryParseCache(filename: "cache.jsonl", directory: root)
    cache.store([1], provider: "p", path: "/a.jsonl", modifiedAt: modifiedAt, size: 1)
    cache.store([2], provider: "p", path: "/b.jsonl", modifiedAt: modifiedAt, size: 1)
    cache.persist()
    let firstWrite = try Data(contentsOf: url)
    try expectEqual(try lines(of: url).filter { !$0.isEmpty }.count, 3, "header plus one line per file")

    cache.persist()
    try expectEqual(try Data(contentsOf: url), firstWrite, "a persist with nothing changed writes nothing")

    cache.store([1, 1], provider: "p", path: "/a.jsonl", modifiedAt: modifiedAt, size: 2)
    cache.persist()
    let secondWrite = try Data(contentsOf: url)
    try expect(secondWrite.count > firstWrite.count, "the changed entry was appended")
    try expectEqual(
        secondWrite.prefix(firstWrite.count),
        firstWrite,
        "existing lines are left in place rather than rewritten"
    )
    try expectEqual(try lines(of: url).filter { !$0.isEmpty }.count, 4, "only the changed file gained a line")

    let reader = TelemetryParseCache(filename: "cache.jsonl", directory: root)
    try expectEqual(
        reader.value([Int].self, provider: "p", path: "/a.jsonl", modifiedAt: modifiedAt, size: 2),
        [1, 1],
        "the appended line supersedes the earlier one"
    )
    try expect(
        reader.value([Int].self, provider: "p", path: "/a.jsonl", modifiedAt: modifiedAt, size: 1) == nil,
        "the superseded identity is no longer served"
    )
    try expectEqual(
        reader.value([Int].self, provider: "p", path: "/b.jsonl", modifiedAt: modifiedAt, size: 1),
        [2],
        "untouched entries survive the append"
    )
}

private func testEvictionsPersistAsTombstones() throws {
    let root = try makeTempRoot("tombstone")
    defer { try? FileManager.default.removeItem(at: root) }
    let present = root.appendingPathComponent("present.jsonl")
    try Data("{}".utf8).write(to: present)
    let vanished = root.appendingPathComponent("vanished.jsonl").path

    let cache = TelemetryParseCache(filename: "cache.jsonl", directory: root)
    cache.store([1], provider: "p", path: present.path, modifiedAt: modifiedAt, size: 2)
    cache.store([2], provider: "p", path: vanished, modifiedAt: modifiedAt, size: 2)
    cache.persist()
    let beforePrune = try fileSize(root.appendingPathComponent("cache.jsonl"))

    cache.prune(provider: "p", keepingNewest: 10)
    cache.persist()
    try expect(
        try fileSize(root.appendingPathComponent("cache.jsonl")) > beforePrune,
        "the eviction is appended as a tombstone"
    )

    let reader = TelemetryParseCache(filename: "cache.jsonl", directory: root)
    try expect(
        reader.value([Int].self, provider: "p", path: vanished, modifiedAt: modifiedAt, size: 2) == nil,
        "a deleted file's entry stays evicted after a reload"
    )
    try expectEqual(
        reader.value([Int].self, provider: "p", path: present.path, modifiedAt: modifiedAt, size: 2),
        [1],
        "a tombstone evicts only its own file"
    )
}

private func testSupersededLinesAreCompacted() throws {
    let root = try makeTempRoot("compact")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("cache.jsonl")

    let cache = TelemetryParseCache(filename: "cache.jsonl", directory: root, minimumCompactionSlack: 0)
    let payload = Array(repeating: 7, count: 500)
    cache.store(payload, provider: "p", path: "/other.jsonl", modifiedAt: modifiedAt, size: 1)
    for size in 1...30 {
        cache.store(payload, provider: "p", path: "/growing.jsonl", modifiedAt: modifiedAt, size: size)
        cache.persist()
    }

    let singleLine = try lines(of: url)[1].utf8.count
    try expect(
        try fileSize(url) <= 5 * singleLine,
        "superseded lines are compacted once they outweigh live ones"
    )
    let reader = TelemetryParseCache(filename: "cache.jsonl", directory: root)
    try expectEqual(
        reader.value([Int].self, provider: "p", path: "/growing.jsonl", modifiedAt: modifiedAt, size: 30),
        payload,
        "compaction keeps the newest version"
    )
    try expectEqual(
        reader.value([Int].self, provider: "p", path: "/other.jsonl", modifiedAt: modifiedAt, size: 1),
        payload,
        "compaction keeps untouched entries"
    )
}

private func testLegacyWholeFileCacheIsImported() throws {
    let root = try makeTempRoot("legacy")
    defer { try? FileManager.default.removeItem(at: root) }
    let legacyURL = root.appendingPathComponent("legacy.jsonl")
    // The whole-file layout that preceded appendable lines.
    let entry = try JSONSerialization.data(withJSONObject: [
        "p": "claude", "f": "/t.jsonl",
        "m": modifiedAt.timeIntervalSince1970, "s": 42,
        "d": Data("[4,5]".utf8).base64EncodedString()
    ])
    try ("{\"version\":2}\n" + String(decoding: entry, as: UTF8.self) + "\n")
        .write(to: legacyURL, atomically: true, encoding: .utf8)

    let cache = TelemetryParseCache(filename: "current.jsonl", directory: root, legacyFilename: "legacy.jsonl")
    try expectEqual(
        cache.value([Int].self, provider: "claude", path: "/t.jsonl", modifiedAt: modifiedAt, size: 42),
        [4, 5],
        "an upgrade keeps the previous build's parsed files"
    )
    cache.persist()
    try expect(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("current.jsonl").path),
        "the imported entries are written in the current layout"
    )
    try expect(!FileManager.default.fileExists(atPath: legacyURL.path), "the legacy file is removed once imported")

    let reader = TelemetryParseCache(filename: "current.jsonl", directory: root, legacyFilename: "legacy.jsonl")
    try expectEqual(
        reader.value([Int].self, provider: "claude", path: "/t.jsonl", modifiedAt: modifiedAt, size: 42),
        [4, 5],
        "the migrated entry reloads from the current file"
    )
}

private func testOldFormatVersionIsDiscarded() throws {
    let root = try makeTempRoot("old-version")
    defer { try? FileManager.default.removeItem(at: root) }
    let entry = try JSONSerialization.data(withJSONObject: [
        "p": "codexTelemetry", "f": "/r.jsonl",
        "m": modifiedAt.timeIntervalSince1970, "s": 100,
        "d": Data("[1]".utf8).base64EncodedString()
    ])
    try ("{\"version\":1}\n" + String(decoding: entry, as: UTF8.self) + "\n")
        .write(to: root.appendingPathComponent("cache.jsonl"), atomically: true, encoding: .utf8)

    let cache = TelemetryParseCache(filename: "cache.jsonl", directory: root)
    try expect(
        cache.value([Int].self, provider: "codexTelemetry", path: "/r.jsonl", modifiedAt: modifiedAt, size: 100) == nil,
        "a previous parser's records are never served"
    )
}

private func testTornAppendIsDroppedAndRewritten() throws {
    let root = try makeTempRoot("torn")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("cache.jsonl")

    let writer = TelemetryParseCache(filename: "cache.jsonl", directory: root)
    writer.store([1], provider: "p", path: "/a.jsonl", modifiedAt: modifiedAt, size: 1)
    writer.persist()
    // A crash part-way through an append.
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"p\":\"p\",\"f\":\"/b.jsonl\",\"m\":1,\"s\":1}\t[9".utf8))
    try handle.close()

    let recovering = TelemetryParseCache(filename: "cache.jsonl", directory: root)
    try expectEqual(
        recovering.value([Int].self, provider: "p", path: "/a.jsonl", modifiedAt: modifiedAt, size: 1),
        [1],
        "complete lines before a torn one are still served"
    )
    try expect(
        recovering.value([Int].self, provider: "p", path: "/b.jsonl", modifiedAt: Date(timeIntervalSince1970: 1), size: 1) == nil,
        "the torn line is ignored"
    )
    recovering.store([3], provider: "p", path: "/c.jsonl", modifiedAt: modifiedAt, size: 1)
    recovering.persist()
    try expect(try Data(contentsOf: url).last == 0x0A, "the next persist rewrites rather than appending to the torn line")

    let reader = TelemetryParseCache(filename: "cache.jsonl", directory: root)
    try expectEqual(
        reader.value([Int].self, provider: "p", path: "/a.jsonl", modifiedAt: modifiedAt, size: 1),
        [1],
        "entries survive the repair"
    )
    try expectEqual(
        reader.value([Int].self, provider: "p", path: "/c.jsonl", modifiedAt: modifiedAt, size: 1),
        [3],
        "the entry stored after the tear survives"
    )
}

private func testPayloadIsDecodedOncePerProcess() throws {
    let root = try makeTempRoot("decode-once")
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = TelemetryParseCache(filename: "cache.jsonl", directory: root)
    writer.store(CountedRecords(values: [1, 2]), provider: "p", path: "/a.jsonl", modifiedAt: modifiedAt, size: 1)
    writer.persist()
    try expect(
        writer.value(CountedRecords.self, provider: "p", path: "/a.jsonl", modifiedAt: modifiedAt, size: 1) != nil,
        "a stored value is served"
    )
    try expectEqual(CountedRecords.decodeCount, 0, "a value stored in this process is never decoded")

    let reader = TelemetryParseCache(filename: "cache.jsonl", directory: root)
    for _ in 0..<3 {
        try expectEqual(
            reader.value(CountedRecords.self, provider: "p", path: "/a.jsonl", modifiedAt: modifiedAt, size: 1),
            CountedRecords(values: [1, 2]),
            "the reloaded value is served"
        )
    }
    try expectEqual(CountedRecords.decodeCount, 1, "an unchanged file's payload is decoded once, not per lookup")
}

private func testForeignWriteForcesRewrite() throws {
    let root = try makeTempRoot("foreign")
    defer { try? FileManager.default.removeItem(at: root) }

    let first = TelemetryParseCache(filename: "cache.jsonl", directory: root)
    first.store([1], provider: "p", path: "/a.jsonl", modifiedAt: modifiedAt, size: 1)
    first.persist()

    // Another process (an older build, a second instance) writes the file.
    let second = TelemetryParseCache(filename: "cache.jsonl", directory: root)
    second.store([2], provider: "p", path: "/b.jsonl", modifiedAt: modifiedAt, size: 1)
    second.persist()

    first.store([3], provider: "p", path: "/c.jsonl", modifiedAt: modifiedAt, size: 1)
    first.persist()

    let reader = TelemetryParseCache(filename: "cache.jsonl", directory: root)
    try expectEqual(
        reader.value([Int].self, provider: "p", path: "/a.jsonl", modifiedAt: modifiedAt, size: 1),
        [1],
        "the rewriting instance keeps its own entries"
    )
    try expectEqual(
        reader.value([Int].self, provider: "p", path: "/c.jsonl", modifiedAt: modifiedAt, size: 1),
        [3],
        "the rewriting instance's new entry is written"
    )
    let fileLines = try lines(of: root.appendingPathComponent("cache.jsonl")).filter { !$0.isEmpty }
    try expectEqual(fileLines.count, 3, "a file changed underneath the cache is rewritten whole, not appended to")
}

// MARK: - QuotaSnapshotStore

private func isolatedDefaults() -> (UserDefaults, String) {
    let suite = "storage-cache-tests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

private func snapshot(
    _ providerID: ProviderID,
    fetchedAt: Date,
    tokens: Double,
    accountSlot: String = ProviderAccountKey.primarySlot
) -> QuotaSnapshot {
    QuotaSnapshot(
        providerID: providerID,
        displayName: providerID.rawValue,
        windows: [
            QuotaWindow(label: "Weekly", windowKind: .weekly, used: tokens, total: nil, resetDate: nil, unit: "tok")
        ],
        events: [UsageEvent(timestamp: fetchedAt.addingTimeInterval(-60), tokens: tokens, model: "m", type: .bucket)],
        fetchedAt: fetchedAt,
        accountSlot: accountSlot
    )
}

private func testSnapshotStoreLoadsWhatAFreshDecodeWould() throws {
    let (defaults, suite) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = QuotaSnapshotStore(defaults: defaults)
    // Fractional seconds do not survive the ISO 8601 date encoding.
    let fetchedAt = Date(timeIntervalSince1970: 1_790_000_000.75)

    store.upsert(snapshot(.claude, fetchedAt: fetchedAt, tokens: 10))
    store.upsert(snapshot(.kimi, fetchedAt: fetchedAt, tokens: 20))
    store.upsert(snapshot(.claude, fetchedAt: fetchedAt.addingTimeInterval(60), tokens: 30))

    let fresh = QuotaSnapshotStore(defaults: defaults).loadSnapshots()
    try expectEqual(store.loadSnapshots(), fresh, "a remembered load matches decoding the stored bytes")
    try expectEqual(fresh.map(\.providerID), [.kimi, .claude], "upserts replace the account and keep the others")
    try expectEqual(fresh.last?.windows.first?.used, 30, "the newest upsert is stored")
    try expectEqual(
        fresh.first?.fetchedAt,
        Date(timeIntervalSince1970: 1_790_000_000),
        "loads see the stored precision, not the caller's"
    )
}

private func testSnapshotStoreSeesOtherWriters() throws {
    let (defaults, suite) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let app = QuotaSnapshotStore(defaults: defaults)
    let other = QuotaSnapshotStore(defaults: defaults)
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    app.upsert(snapshot(.claude, fetchedAt: now, tokens: 1))
    try expectEqual(app.loadSnapshots().count, 1, "the store's own write is loaded")

    other.upsert(snapshot(.kimi, fetchedAt: now, tokens: 2))
    try expectEqual(
        app.loadSnapshots().map(\.providerID),
        [.claude, .kimi],
        "a write by another store or process is picked up"
    )

    app.upsert(snapshot(.claude, fetchedAt: now, tokens: 3))
    let reloaded = QuotaSnapshotStore(defaults: defaults).loadSnapshots()
    try expectEqual(reloaded.map(\.providerID), [.kimi, .claude], "the other writer's account survives an upsert")
    try expectEqual(reloaded.first?.windows.first?.used, 2, "the other writer's snapshot is written unchanged")
    try expectEqual(reloaded.last?.windows.first?.used, 3, "the upsert is written")

    app.clearAll()
    try expectEqual(app.loadSnapshots(), [], "clearing forgets the remembered snapshots")
}

private func testSnapshotStoreKeepsSecondaryAccountsApart() throws {
    let (defaults, suite) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = QuotaSnapshotStore(defaults: defaults)
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    store.upsert(snapshot(.claude, fetchedAt: now, tokens: 1))
    store.upsert(snapshot(.claude, fetchedAt: now, tokens: 2, accountSlot: "work"))
    store.upsert(snapshot(.claude, fetchedAt: now, tokens: 3))

    let stored = QuotaSnapshotStore(defaults: defaults).loadSnapshots()
    try expectEqual(stored.count, 2, "each account keeps one snapshot")
    try expectEqual(
        stored.first { !$0.isPrimaryAccount }?.windows.first?.used,
        2,
        "the secondary account's JSON is reused unchanged"
    )
    try expectEqual(
        stored.first { $0.isPrimaryAccount }?.windows.first?.used,
        3,
        "the primary account is re-encoded"
    )
}

// MARK: - Runner

@main
private enum StorageCacheTestRunner {
    static func main() throws {
        try testUnchangedFilesAreServedAcrossInstances()
        try testPersistAppendsOnlyChangedEntries()
        try testEvictionsPersistAsTombstones()
        try testSupersededLinesAreCompacted()
        try testLegacyWholeFileCacheIsImported()
        try testOldFormatVersionIsDiscarded()
        try testTornAppendIsDroppedAndRewritten()
        try testPayloadIsDecodedOncePerProcess()
        try testForeignWriteForcesRewrite()
        try testSnapshotStoreLoadsWhatAFreshDecodeWould()
        try testSnapshotStoreSeesOtherWriters()
        try testSnapshotStoreKeepsSecondaryAccountsApart()
        print("Storage cache tests passed")
    }
}
