import Foundation

/// Streams the object elements of one JSON array without holding the document:
/// the top-level array when `key` is nil, otherwise the array stored under `key` in
/// the top-level object. Checkpoints and chat documents can exceed 100 MB, and one
/// chat message can embed a 20 MB attachment, so a string longer than
/// `maximumStringBytes` reaches the decoder empty; usage fields are never that long.
nonisolated enum JSONArrayObjectStream {
    static let maximumElementBytes = 16 * 1024 * 1024
    static let maximumStringBytes = 64 * 1024

    /// Returns the number of elements that could not be decoded or were too large.
    static func read(url: URL, key: String?, _ handleObject: ([String: Any]) throws -> Void) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let wanted = key.map { Array($0.utf8) }
        var depth = 0, inString = false, escaped = false
        var elementDepth: Int?          // depth inside the target array
        var element = Data(), capturing = false, oversized = false, malformed = 0
        var stringStart = 0, eliding = false   // content offset of the element's open string
        var keyBytes: [UInt8] = [], collectingKey = false, lastString: [UInt8]?, pendingKey: [UInt8]?
        while let chunk = try ModelUsageLogParser.nextChunk(handle), !chunk.isEmpty {
            try Task.checkCancellation()
            try chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var runStart = capturing && !eliding ? 0 : -1
                for index in 0..<bytes.count {
                    let byte = bytes[index]
                    if inString {
                        if escaped { escaped = false }
                        else if byte == 0x5C { escaped = true }
                        else if byte == 0x22 {
                            inString = false
                            if collectingKey { lastString = keyBytes; collectingKey = false }
                            if eliding { eliding = false; runStart = index }
                            continue
                        }
                        if collectingKey { keyBytes.append(byte) }
                        if capturing, !eliding, !oversized, element.count + index - runStart - stringStart > maximumStringBytes {
                            element.append(base + runStart, count: index - runStart)
                            element.count = stringStart
                            eliding = true; runStart = -1
                        }
                        continue
                    }
                    switch byte {
                    case 0x22:
                        inString = true
                        if capturing { stringStart = element.count + index - runStart + 1 }
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

/// Internet timestamps with or without fractional seconds (any precision).
nonisolated struct ModelUsageTimestamps {
    private let fractional: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
    }()
    private let plain = ISO8601DateFormatter()

    func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return fractional.date(from: text) ?? plain.date(from: text)
    }
}

/// Grok Build CLI `sessions/<project>/<session>/usage.json`: one record per model per
/// turn with its API call count. Input includes cached reads and cache creation.
nonisolated enum GrokUsageParser {
    static func read(url: URL, fileID: String, emit: (ModelUsageCall) throws -> Void) throws -> Int {
        let times = ModelUsageTimestamps()
        return try JSONArrayObjectStream.read(url: url, key: "turns") { turn in
            for call in calls(from: turn, fileID: fileID, times: times) { try emit(call) }
        }
    }

    static func calls(from turn: [String: Any], fileID: String, times: ModelUsageTimestamps) -> [ModelUsageCall] {
        guard let ended = times.date(turn["endedAt"]) else { return [] }
        let turnNumber = (turn["turnNumber"] as? NSNumber)?.intValue ?? Int(ended.timeIntervalSince1970)
        let perModel = (turn["modelUsage"] as? [String: Any])?.compactMapValues { $0 as? [String: Any] } ?? [:]
        let usages = perModel.isEmpty ? [(TaskWraithUsageParser.text(turn["primaryModelId"]) ?? "Unknown model", turn)] : perModel.map { ($0.key, $0.value) }
        return usages.sorted { $0.0 < $1.0 }.compactMap { model, usage in
            let number = { TaskWraithUsageParser.number(usage[$0]) ?? 0 }
            let input = number("inputTokens"), output = number("outputTokens")
            let cacheRead = min(input, number("cachedReadTokens")), cacheWrite = min(input - cacheRead, number("cacheCreationTokens"))
            let tokens = ModelTokenCounts(input: input - cacheRead - cacheWrite, cacheRead: cacheRead, cacheWrite: cacheWrite,
                output: output, reasoning: min(output, number("reasoningTokens")),
                unsplit: max(0, number("totalTokens") - input - output))
            guard tokens.total > 0 else { return nil }
            return ModelUsageCall(id: ModelUsageLogParser.hash("grok|\(fileID)|\(turnNumber)|\(model)"), source: LocalModelUsageSource.grok.rawValue,
                timestamp: ended, model: String(model.prefix(256)), tokens: tokens, calls: Int(number("modelCalls")))
        }
    }
}

/// Gemini CLI chats under `tmp/<project>/chats/`: whole JSON documents or JSON Lines.
/// Each model message is one API response. `input` includes `cached`; `tool` prompt
/// tokens bill as input and `thoughts` as output, so the reported total reconciles.
nonisolated enum GeminiChatParser {
    static func read(url: URL, fileID: String, emit: (ModelUsageCall) throws -> Void) throws -> Int {
        let times = ModelUsageTimestamps()
        let consume: ([String: Any]) throws -> Void = { message in
            if let call = call(from: message, fileID: fileID, times: times) { try emit(call) }
        }
        return url.pathExtension == "jsonl"
            ? try ModelUsageLogParser.readLines(url: url, consume)
            : try JSONArrayObjectStream.read(url: url, key: "messages", consume)
    }

    static func call(from message: [String: Any], fileID: String, times: ModelUsageTimestamps) -> ModelUsageCall? {
        guard let usage = message["tokens"] as? [String: Any], let timestamp = times.date(message["timestamp"]) else { return nil }
        let number = { TaskWraithUsageParser.number(usage[$0]) ?? 0 }
        let prompt = number("input"), cached = min(prompt, number("cached")), thoughts = number("thoughts")
        var tokens = ModelTokenCounts(input: prompt - cached + number("tool"), cacheRead: cached,
            output: number("output") + thoughts, reasoning: thoughts)
        tokens.unsplit = max(0, number("total") - tokens.total)
        guard tokens.total > 0 else { return nil }
        let identity = TaskWraithUsageParser.text(message["id"]) ?? "\(fileID)|\(timestamp.timeIntervalSince1970)"
        return ModelUsageCall(id: ModelUsageLogParser.hash("gemini|\(identity)"), source: LocalModelUsageSource.gemini.rawValue,
            timestamp: timestamp, model: String((TaskWraithUsageParser.text(message["model"]) ?? "Unknown model").prefix(256)), tokens: tokens)
    }
}

/// Kimi CLI `sessions/**/wire.jsonl`, one record per API step in either format:
/// Kimi Code's `usage.record` (millisecond time, model alias such as `kimi-code/k3`)
/// or the older CLI's `StatusUpdate`, which names no model, so none is assumed.
/// Kimi Code's migration copied old sessions without their usage, so each folder
/// holds only its own era.
nonisolated enum KimiWireParser {
    static func read(url: URL, fileID: String, emit: (ModelUsageCall) throws -> Void) throws -> Int {
        var line = 0
        return try ModelUsageLogParser.readLines(url: url) { row in
            line += 1
            if let call = call(from: row, fileID: fileID, line: line) { try emit(call) }
        }
    }

    static func call(from row: [String: Any], fileID: String, line: Int) -> ModelUsageCall? {
        let usage: [String: Any], seconds: Double, model: String, identity: String
        let keys: (input: String, cacheRead: String, cacheWrite: String)
        if row["type"] as? String == "usage.record" {
            // Only per-request "turn" records are known; another scope could be a sum.
            guard (row["usageScope"] as? String ?? "turn") == "turn", let values = row["usage"] as? [String: Any],
                  let milliseconds = TaskWraithUsageParser.number(row["time"]), milliseconds > 0 else { return nil }
            usage = values; seconds = milliseconds / 1000
            model = String((TaskWraithUsageParser.text(row["model"]) ?? "Unknown model").prefix(256))
            identity = "\(fileID)|\(line)"
            keys = ("inputOther", "inputCacheRead", "inputCacheCreation")
        } else {
            guard let message = row["message"] as? [String: Any], message["type"] as? String == "StatusUpdate",
                  let payload = message["payload"] as? [String: Any], let values = payload["token_usage"] as? [String: Any],
                  let stamp = TaskWraithUsageParser.number(row["timestamp"]), stamp > 0 else { return nil }
            usage = values; seconds = stamp; model = "Unknown model"
            identity = TaskWraithUsageParser.text(payload["message_id"]) ?? "\(fileID)|\(line)"
            keys = ("input_other", "input_cache_read", "input_cache_creation")
        }
        let number = { TaskWraithUsageParser.number(usage[$0]) ?? 0 }
        let tokens = ModelTokenCounts(input: number(keys.input), cacheRead: number(keys.cacheRead),
            cacheWrite: number(keys.cacheWrite), output: number("output"))
        guard tokens.total > 0 else { return nil }
        return ModelUsageCall(id: ModelUsageLogParser.hash("kimi|\(identity)"), source: LocalModelUsageSource.kimi.rawValue,
            timestamp: Date(timeIntervalSince1970: seconds), model: model, tokens: tokens)
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
