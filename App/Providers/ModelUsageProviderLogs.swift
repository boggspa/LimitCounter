import Foundation

/// Streams the object elements of one JSON array without holding the document:
/// the top-level array when `key` is nil, otherwise the array stored under `key` in
/// the top-level object. Checkpoints and chat documents can exceed 100 MB.
nonisolated enum JSONArrayObjectStream {
    static let maximumElementBytes = 16 * 1024 * 1024

    /// Returns the number of elements that could not be decoded or were too large.
    static func read(url: URL, key: String?, _ handleObject: ([String: Any]) throws -> Void) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let wanted = key.map { Array($0.utf8) }
        var depth = 0, inString = false, escaped = false
        var elementDepth: Int?          // depth inside the target array
        var element = Data(), capturing = false, oversized = false, malformed = 0
        var keyBytes: [UInt8] = [], collectingKey = false, lastString: [UInt8]?, pendingKey: [UInt8]?
        while let chunk = try handle.read(upToCount: 512 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            try chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var runStart = capturing ? 0 : -1
                for index in 0..<bytes.count {
                    let byte = bytes[index]
                    if inString {
                        if escaped { escaped = false }
                        else if byte == 0x5C { escaped = true }
                        else if byte == 0x22 {
                            inString = false
                            if collectingKey { lastString = keyBytes; collectingKey = false }
                            continue
                        }
                        if collectingKey { keyBytes.append(byte) }
                        continue
                    }
                    switch byte {
                    case 0x22:
                        inString = true
                        if !capturing, depth == 1, wanted != nil { collectingKey = true; keyBytes.removeAll(keepingCapacity: true) }
                    case 0x3A where depth == 1 && !capturing:
                        pendingKey = lastString
                    case 0x2C where depth == 1 && !capturing:
                        pendingKey = nil; lastString = nil
                    case 0x5B, 0x7B:
                        if byte == 0x5B, elementDepth == nil,
                           (wanted == nil && depth == 0) || (wanted != nil && depth == 1 && pendingKey == wanted) {
                            elementDepth = depth + 1
                        } else if byte == 0x7B, let target = elementDepth, depth == target, !capturing {
                            capturing = true; oversized = false; element.removeAll(keepingCapacity: true); runStart = index
                        }
                        depth += 1
                    case 0x5D, 0x7D:
                        depth -= 1
                        if capturing, let target = elementDepth, depth == target, byte == 0x7D {
                            if !oversized { element.append(base + runStart, count: index - runStart + 1) }
                            capturing = false; runStart = -1
                            if oversized { malformed += 1; continue }
                            try autoreleasepool {
                                guard let object = try? JSONSerialization.jsonObject(with: element) as? [String: Any] else { malformed += 1; return }
                                try handleObject(object)
                            }
                        } else if byte == 0x5D, let target = elementDepth, depth == target - 1 {
                            elementDepth = nil
                        }
                    default: break
                    }
                }
                if capturing, runStart >= 0, !oversized {
                    element.append(base + runStart, count: bytes.count - runStart)
                    if element.count > maximumElementBytes { oversized = true; element.removeAll(keepingCapacity: false) }
                }
            }
        }
        return malformed + (capturing ? 1 : 0)
    }
}

/// TaskWraith's usage store: a `usage.json` checkpoint plus JSON Lines journal and
/// archive artifacts. `id` is TaskWraith's own idempotency key across all three.
nonisolated enum TaskWraithUsageParser {
    static let files = ["usage.json", "usage-journal.jsonl", "usage-archive.jsonl"]
    /// TaskWraith drives these CLIs, whose native transcripts are indexed on their own.
    static let nativeTranscriptProviders: Set<String> = ["codex", "claude"]

    static func read(url: URL, fileID: String, emit: (ModelUsageCall) throws -> Void) throws -> Int {
        let consume: ([String: Any]) throws -> Void = { record in
            if let call = call(from: record, fileID: fileID) { try emit(call) }
        }
        return url.pathExtension == "jsonl"
            ? try ModelUsageLogParser.readLines(url: url, consume)
            : try JSONArrayObjectStream.read(url: url, key: nil, consume)
    }

    /// One whole run per record: its call count is unknown, so a long-context tier is
    /// bounded rather than chosen. Prompts and responses in a record are never read.
    static func call(from record: [String: Any], fileID: String) -> ModelUsageCall? {
        guard let provider = (record["provider"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces),
              !provider.isEmpty, !provider.contains("/"), !nativeTranscriptProviders.contains(provider),
              (record["usageKind"] as? String ?? "run") == "run",
              // Time-bucket aggregates of external scans are not TaskWraith runs.
              record["runCount"] == nil,
              let milliseconds = number(record["timestamp"]), milliseconds > 0 else { return nil }
        let input = number(record["inputTokens"]) ?? 0, output = number(record["outputTokens"]) ?? 0
        let cacheRead = number(record["cacheReadInputTokens"]) ?? 0, cacheWrite = number(record["cacheCreationInputTokens"]) ?? 0
        let total = number(record["totalTokens"]) ?? 0
        let parts = input + output + cacheRead + cacheWrite
        let tokens: ModelTokenCounts
        if total <= 0 || abs(total - parts) < 0.5 {
            tokens = ModelTokenCounts(input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output)
        } else if cacheRead + cacheWrite > 0, cacheRead + cacheWrite <= input, abs(total - (input + output)) < 0.5 {
            // Cache-inclusive input (as Muse reports): the cache fields are subsets of input.
            tokens = ModelTokenCounts(input: input - cacheRead - cacheWrite, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output)
        } else if total > parts {
            // The inclusive total exceeds what was itemised; the excess keeps no category.
            tokens = ModelTokenCounts(input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output, unsplit: total - parts)
        } else {
            tokens = ModelTokenCounts(unsplit: total)
        }
        guard tokens.isValid, tokens.total > 0 else { return nil }
        let model = text(record["model"]) ?? "unknown"
        let rateModel = text(record["costRateModel"])
        let identity = text(record["id"])
            ?? "\(fileID)|\(text(record["runId"]) ?? "")|\(Int(milliseconds))|\(provider)|\(model)"
        return ModelUsageCall(id: ModelUsageLogParser.hash("taskwraith|\(identity)"), source: LocalModelUsageSource.taskwraith.rawValue,
            timestamp: Date(timeIntervalSince1970: milliseconds / 1000), model: String("\(provider)/\(model)".prefix(256)),
            tokens: tokens, rateModel: rateModel.map { String("\(provider)/\($0)".prefix(256)) }, calls: 0,
            inferred: record["tokenCountConfidence"] as? String == "estimated")
    }

    static func text(_ value: Any?) -> String? {
        guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func number(_ value: Any?) -> Double? {
        guard let value = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init),
              value.isFinite, value >= 0 else { return nil }
        return value
    }
}
