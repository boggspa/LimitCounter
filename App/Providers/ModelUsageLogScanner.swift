import Foundation
import CryptoKit

/// Owns the local ledger off the main actor. Only callers holding an existing folder
/// grant may supply roots; this type never discovers home folders or reads credentials.
actor ModelUsageLogScanner {
    static let shared = ModelUsageLogScanner()
    static let parserVersion = 1
    private let directory: URL

    init(directory: URL = ModelUsageArchiveStore.directory) { self.directory = directory }

    func scan(roots: [LocalModelUsageSource: URL], now: Date = Date(),
              progress: @Sendable (String) async -> Void = { _ in }) async throws -> ModelUsageArchive {
        let ledger = try ModelUsageLedger(url: directory.appendingPathComponent("requests-v1.sqlite"))
        var archive = ModelUsageArchiveStore.load(from: directory)
        let previousArchive = archive
        var coverage = archive.coverage
        for source in LocalModelUsageSource.allCases {
            guard let root = roots[source] else { continue }
            let folders: [URL] = source == .codex
                ? [root.appendingPathComponent("sessions"), root.appendingPathComponent("archived_sessions")]
                : [root.lastPathComponent == "projects" ? root : root.appendingPathComponent("projects")]
            var files: [(URL, Date, Int)] = []
            var failed = 0
            for folder in folders {
                guard FileManager.default.fileExists(atPath: folder.path) else { continue }
                guard let enumerator = FileManager.default.enumerator(at: folder,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey],
                    options: [.skipsHiddenFiles], errorHandler: { _, _ in failed += 1; return true }) else { failed += 1; continue }
                while let url = enumerator.nextObject() as? URL {
                    guard url.pathExtension == "jsonl" else { continue }
                    guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]),
                          info.isRegularFile == true, info.isSymbolicLink != true,
                          let modified = info.contentModificationDate, let size = info.fileSize else { continue }
                    files.append((url, modified, size))
                }
            }
            files.sort { $0.1 > $1.1 }
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                if index % 25 == 0 { await progress("\(source.title) · \(index + 1) of \(files.count) logs") }
                let key = ModelUsageLogParser.hash(file.0.standardizedFileURL.path)
                if try ledger.isCurrent(source: source.rawValue, file: key, modified: file.1, bytes: file.2, version: Self.parserVersion) { continue }
                do {
                    try ledger.replaceFile(source: source.rawValue, file: key, modified: file.1, bytes: file.2, version: Self.parserVersion) { emit in
                        let malformed = try ModelUsageLogParser.read(url: file.0, source: source, fileID: key, emit: emit)
                        let after = try file.0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        // A growing log is safely retried; do not cache a partial version as complete.
                        guard after.fileSize == file.2, after.contentModificationDate == file.1 else { throw ModelUsageError.incompleteFile }
                        return malformed
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { failed += 1 }
            }
            coverage.removeAll { $0.source == source.rawValue }
            coverage.append(ModelUsageCoverage(source: source.rawValue, scannedAt: now, files: files.count,
                unreadableFiles: failed, malformedLines: try ledger.malformedLines(source: source.rawValue),
                status: files.isEmpty ? "No readable logs in the connected folder" : (failed > 0 ? "Partial scan; cached history retained" : "Local logs indexed")))
        }
        try ledger.prune(now: now)
        archive = ModelUsageArchive(generatedAt: now, buckets: try ledger.rollups(now: now), coverage: coverage)
        for index in archive.coverage.indices {
            let rows = archive.buckets.filter { $0.source == archive.coverage[index].source }
            archive.coverage[index].firstEvent = rows.map(\.start).min()
            archive.coverage[index].lastEvent = rows.map(\.start).max()
        }
        if archive.hasSameContent(as: previousArchive) { return previousArchive }
        try ModelUsageArchiveStore.save(archive, to: directory)
        return archive
    }
}

/// Streaming parser: bounded lines and no tail/file-count truncation. Per-call records
/// survive only as token counts, model, time and hashed identity in the local ledger.
nonisolated enum ModelUsageLogParser {
    static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func read(url: URL, source: LocalModelUsageSource, fileID: String,
                     emit: (ModelUsageCall) throws -> Void) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var parser = State(source: source, fileID: fileID)
        var buffer = Data(), malformed = 0, skipping = false
        func consume(_ line: Data) throws {
            guard !line.isEmpty else { return }
            try autoreleasepool {
                guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { malformed += 1; return }
                if let call = parser.consume(json) { try emit(call) }
            }
        }
        while let chunk = try handle.read(upToCount: 512 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            buffer.append(chunk)
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 10) {
                if !skipping { try consume(Data(buffer[start..<newline])) }
                skipping = false
                start = buffer.index(after: newline)
            }
            buffer.removeSubrange(buffer.startIndex..<start)
            if buffer.count > 16 * 1024 * 1024 { buffer.removeAll(keepingCapacity: false); skipping = true; malformed += 1 }
        }
        if !skipping { try consume(buffer) }
        return malformed
    }

    nonisolated struct State {
        let source: LocalModelUsageSource
        let fileID: String
        var model = "Unknown model"
        var session = ""
        var previous: [String: Double]?
        var sequence = 0
        private let fractional: ISO8601DateFormatter = {
            let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
        }()
        private let plain = ISO8601DateFormatter()

        init(source: LocalModelUsageSource, fileID: String) { self.source = source; self.fileID = fileID }

        mutating func consume(_ row: [String: Any]) -> ModelUsageCall? {
            let payload = row["payload"] as? [String: Any] ?? [:]
            if source == .codex {
                if row["type"] as? String == "session_meta" { session = payload["id"] as? String ?? session }
                if row["type"] as? String == "turn_context" { model = cleanModel(payload["model"]) }
            }
            guard let stamp = row["timestamp"] as? String,
                  let timestamp = fractional.date(from: stamp) ?? plain.date(from: stamp) else { return nil }
            if source == .claude {
                guard let message = row["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] else { return nil }
                let counts = ModelTokenCounts(input: number(usage, "input_tokens"), cacheRead: number(usage, "cache_read_input_tokens"),
                    cacheWrite: number(usage, "cache_creation_input_tokens"), output: number(usage, "output_tokens"),
                    reasoning: number(usage["output_tokens_details"] as? [String: Any] ?? [:], "thinking_tokens"))
                guard counts.total > 0 else { return nil }
                let request = row["requestId"] as? String ?? ""
                let messageID = message["id"] as? String ?? ""
                let identity = request.isEmpty && messageID.isEmpty
                    ? "\(fileID)|\(row["uuid"] as? String ?? stamp)" : "\(request)|\(messageID)"
                return ModelUsageCall(id: hash(identity), source: source.rawValue, timestamp: timestamp, model: cleanModel(message["model"]), tokens: counts)
            }
            guard payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any] else { return nil }
            let keys = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens"]
            let current = Dictionary(uniqueKeysWithValues: keys.map { ($0, number(total, $0)) })
            let currentTotal = (current["input_tokens"] ?? 0) + (current["output_tokens"] ?? 0)
            let priorTotal = (previous?["input_tokens"] ?? 0) + (previous?["output_tokens"] ?? 0)
            if previous != nil && currentTotal == priorTotal { return nil }
            var delta = current
            if let last = info["last_token_usage"] as? [String: Any],
               number(last, "input_tokens") + number(last, "output_tokens") > 0 {
                // A resumed/forked rollout can inherit cumulative history in its first
                // event. The last-call vector is authoritative even on that first row.
                delta = Dictionary(uniqueKeysWithValues: keys.map { ($0, number(last, $0)) })
            } else if previous != nil, currentTotal > priorTotal {
                for key in keys { delta[key] = max(0, (current[key] ?? 0) - (previous?[key] ?? 0)) }
            }
            previous = current
            sequence += 1
            let input = delta["input_tokens"] ?? 0
            let cached = min(input, delta["cached_input_tokens"] ?? 0)
            let write = min(max(0, input - cached), delta["cache_write_input_tokens"] ?? 0)
            let output = delta["output_tokens"] ?? 0
            let counts = ModelTokenCounts(input: max(0, input - cached - write), cacheRead: cached, cacheWrite: write,
                output: output, reasoning: min(output, delta["reasoning_output_tokens"] ?? 0))
            guard counts.total > 0 else { return nil }
            let identity = "\(session.isEmpty ? fileID : session)|\(stamp)|\(currentTotal)"
            return ModelUsageCall(id: hash(identity), source: source.rawValue, timestamp: timestamp, model: model, tokens: counts)
        }

        private func number(_ dictionary: [String: Any], _ key: String) -> Double {
            let value = (dictionary[key] as? NSNumber)?.doubleValue ?? 0
            return value.isFinite && value >= 0 ? value : 0
        }
        private func cleanModel(_ value: Any?) -> String {
            guard let raw = value as? String else { return "Unknown model" }
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Unknown model" : String(name.prefix(256))
        }
    }
}
