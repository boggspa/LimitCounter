import CryptoKit
import Foundation
import SQLite3

public struct CodexTelemetryReader {
    private let fileManager: FileManager
    private let sessionScanLookback: TimeInterval
    private let maxSessionTelemetryFiles: Int
    private let maxSessionTelemetryBytes: Int
    private let maxTextTelemetryBytes: Int

    public init(
        fileManager: FileManager = .default,
        sessionScanLookback: TimeInterval = 3 * 24 * 60 * 60,
        maxSessionTelemetryFiles: Int = 12,
        maxSessionTelemetryBytes: Int = 4 * 1024 * 1024,
        maxTextTelemetryBytes: Int = 8 * 1024 * 1024
    ) {
        self.fileManager = fileManager
        self.sessionScanLookback = sessionScanLookback
        self.maxSessionTelemetryFiles = maxSessionTelemetryFiles
        self.maxSessionTelemetryBytes = maxSessionTelemetryBytes
        self.maxTextTelemetryBytes = maxTextTelemetryBytes
    }

    public func readSnapshot(rootURL: URL) async throws -> QuotaSnapshot {
        try loadSnapshot(rootURL: rootURL)
    }

    private func loadSnapshot(rootURL: URL) throws -> QuotaSnapshot {
        let now = Date()
        let dayStart = now.addingTimeInterval(-24 * 60 * 60)
        let weekStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let monthStart = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let scanFiles = discoverTelemetryURLs(in: rootURL)

        var sessionEvents = 0.0
        var weekEvents = 0.0
        var monthEvents = 0.0
        var promptEvents24h = 0.0
        var responseEvents24h = 0.0
        var toolEvents24h = 0.0
        var approvalEvents24h = 0.0
        var tokenCount24h = 0.0
        var tokenCount7d = 0.0
        var conversationIDs = Set<String>()
        var lastActivity = Date.distantPast
        var events: [UsageEvent] = []

        for telemetryInfo in scanFiles {
            let records = (try? readTelemetryRecords(from: telemetryInfo.url)) ?? []
            guard !records.isEmpty else { continue }

            for record in records {
                events.append(UsageEvent(
                    id: stableEventID(for: record),
                    timestamp: record.timestamp,
                    tokens: record.tokenCount,
                    model: "Codex",
                    type: .telemetry
                ))

                if record.timestamp >= now.addingTimeInterval(-5 * 60 * 60) {
                    sessionEvents += 1
                }
                if record.timestamp >= weekStart {
                    weekEvents += 1
                }
                if record.timestamp >= monthStart {
                    monthEvents += 1
                }
                if record.timestamp >= dayStart {
                    tokenCount24h += record.tokenCount
                    if record.isPrompt { promptEvents24h += 1 }
                    if record.isResponse { responseEvents24h += 1 }
                    if record.isToolEvent { toolEvents24h += 1 }
                    if record.isApprovalEvent { approvalEvents24h += 1 }
                }
                if record.timestamp >= weekStart {
                    tokenCount7d += record.tokenCount
                }
                if let conversationID = record.conversationID {
                    conversationIDs.insert(conversationID)
                }
                if record.timestamp > lastActivity {
                    lastActivity = record.timestamp
                }
            }
        }

        guard monthEvents > 0 || tokenCount24h > 0 || !conversationIDs.isEmpty else {
            throw CodexUsageError.telemetryUnavailable
        }

        let windows = [
            QuotaWindow(
                label: "Session Events",
                windowKind: .session,
                used: sessionEvents,
                total: nil,
                unit: "evt",
                subtitle: "Events in the last 5 hours"
            ),
            QuotaWindow(
                label: "Weekly Usage",
                windowKind: .weekly,
                used: weekEvents,
                total: nil,
                unit: "evt",
                subtitle: "Events in the last 7 days"
            )
        ]

        let stats = [
            QuotaStat(label: "24H Tokens", value: tokenCount24h, unit: "tok"),
            QuotaStat(label: "7D Tokens", value: tokenCount7d, unit: "tok"),
            QuotaStat(label: "24H Prompts", value: promptEvents24h, unit: "evt"),
            QuotaStat(label: "24H Responses", value: responseEvents24h, unit: "evt"),
            QuotaStat(label: "24H Tools", value: toolEvents24h, unit: "evt"),
            QuotaStat(label: "Active Threads", value: Double(conversationIDs.count), unit: "threads")
        ]

        return QuotaSnapshot(
            providerID: .codexTelemetry,
            displayName: "Codex Telemetry",
            planName: "Local Logs",
            windows: windows,
            stats: stats,
            events: Array(events.sorted { $0.timestamp > $1.timestamp }.prefix(1_000)),
            fetchState: .success,
            fetchedAt: lastActivity > .distantPast ? lastActivity : now
        )
    }

    private func discoverTelemetryURLs(in root: URL) -> [CodexTelemetryFileInfo] {
        let existing = telemetryCandidateURLs(in: root).compactMap { url -> CodexTelemetryFileInfo? in
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return CodexTelemetryFileInfo(
                url: url,
                modificationDate: fileModificationDate(for: url),
                fileSize: fileSize(for: url)
            )
        }

        return (existing + sessionTelemetryURLs(in: root)).sorted { lhs, rhs in
            lhs.modificationDate > rhs.modificationDate
        }
    }

    private func telemetryCandidateURLs(in root: URL) -> [URL] {
        if root.lastPathComponent == "log" {
            let parent = root.deletingLastPathComponent()
            return [
                root.appendingPathComponent("codex-tui.log"),
                root.appendingPathComponent("codex.log"),
                parent.appendingPathComponent("logs_2.sqlite"),
                parent.appendingPathComponent("session_index.jsonl")
            ]
        }

        return [
            root.appendingPathComponent("logs_2.sqlite"),
            root.appendingPathComponent("session_index.jsonl"),
            root.appendingPathComponent("log/codex-tui.log"),
            root.appendingPathComponent("log/codex.log")
        ]
    }

    private func sessionTelemetryURLs(in root: URL) -> [CodexTelemetryFileInfo] {
        let sessionsRoot = root.lastPathComponent == "sessions"
            ? root
            : root.appendingPathComponent("sessions")
        guard isDirectory(sessionsRoot) else { return [] }

        let cutoff = Date().addingTimeInterval(-sessionScanLookback)
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [CodexTelemetryFileInfo] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            let modificationDate = values.contentModificationDate ?? fileModificationDate(for: url)
            guard modificationDate >= cutoff else { continue }
            results.append(
                CodexTelemetryFileInfo(
                    url: url,
                    modificationDate: modificationDate,
                    fileSize: values.fileSize ?? fileSize(for: url)
                )
            )
        }

        return Array(
            results
                .sorted { lhs, rhs in
                    if lhs.modificationDate == rhs.modificationDate {
                        return lhs.fileSize < rhs.fileSize
                    }
                    return lhs.modificationDate > rhs.modificationDate
                }
                .prefix(maxSessionTelemetryFiles)
        )
    }

    private func readTelemetryRecords(from url: URL) throws -> [CodexTelemetryRecord] {
        if url.lastPathComponent == "logs_2.sqlite" {
            return try readSQLiteTelemetryRecords(from: url)
        }

        let data = try telemetryTextData(from: url)
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }

        var records: [CodexTelemetryRecord] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: lineData) else { continue }
            if let record = parseRecord(from: json) {
                records.append(record)
            }
        }

        return records
    }

    private func telemetryTextData(from url: URL) throws -> Data {
        let maxBytes = isSessionTelemetryURL(url) ? maxSessionTelemetryBytes : maxTextTelemetryBytes
        let size = fileSize(for: url)
        guard size > maxBytes else {
            return try Data(contentsOf: url)
        }

        return try tailData(from: url, maxBytes: maxBytes)
    }

    private func tailData(from url: URL, maxBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let endOffset = try handle.seekToEnd()
        let startOffset = endOffset > UInt64(maxBytes) ? endOffset - UInt64(maxBytes) : 0
        try handle.seek(toOffset: startOffset)
        guard var data = try handle.readToEnd() else {
            return Data()
        }

        if startOffset > 0,
           let firstNewline = data.firstIndex(of: 0x0A),
           firstNewline < data.index(before: data.endIndex) {
            let nextLine = data.index(after: firstNewline)
            data = Data(data[nextLine..<data.endIndex])
        }

        return data
    }

    private func readSQLiteTelemetryRecords(from url: URL) throws -> [CodexTelemetryRecord] {
        guard fileManager.isReadableFile(atPath: url.path) else {
            return []
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return []
        }
        defer { sqlite3_close(db) }

        let query = """
        SELECT ts, ts_nanos, target, feedback_log_body, thread_id
        FROM (
            SELECT ts, ts_nanos, target, feedback_log_body, thread_id
            FROM logs
            ORDER BY ts DESC, ts_nanos DESC, id DESC
            LIMIT 50000
        )
        ORDER BY ts ASC, ts_nanos ASC;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var records: [CodexTelemetryRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let ts = sqlite3_column_int64(statement, 0)
            let tsNanos = sqlite3_column_int64(statement, 1)
            let target = stringValue(forColumn: 2, statement: statement) ?? ""
            let body = stringValue(forColumn: 3, statement: statement) ?? ""
            let threadID = stringValue(forColumn: 4, statement: statement)

            let timestamp = Date(timeIntervalSince1970: Double(ts) + Double(tsNanos) / 1_000_000_000.0)
            let embeddedJSON = embeddedJSONObject(from: body)
            let eventName = extractEventName(from: embeddedJSON, target: target, body: body)
            let tokenCount = tokenEstimate(
                from: embeddedJSON,
                eventName: eventName,
                target: target,
                body: body
            )

            records.append(
                CodexTelemetryRecord(
                    timestamp: timestamp,
                    conversationID: threadID,
                    eventName: eventName,
                    tokenCount: tokenCount,
                    isPrompt: classifyPrompt(target: target, body: body),
                    isResponse: classifyResponse(target: target, body: body),
                    isToolEvent: classifyToolEvent(target: target, body: body),
                    isApprovalEvent: classifyApprovalEvent(target: target, body: body)
                )
            )
        }

        return records
    }

    private func parseRecord(from json: Any) -> CodexTelemetryRecord? {
        guard let timestamp = firstDate(in: json, keys: ["timestamp", "time", "created_at", "createdAt", "date"]) else {
            return nil
        }

        if let tokenCountRecord = parseSessionTokenCountRecord(from: json, timestamp: timestamp) {
            return tokenCountRecord
        }

        let eventName = firstString(in: json, keys: ["event", "name", "type", "kind", "metric"]) ?? ""
        let conversationID = firstString(
            in: json,
            keys: ["conversation_id", "conversationId", "thread_id", "threadId", "session_id", "sessionId", "chat_id", "chatId"]
        )

        let totalTokens = tokenEstimate(
            from: json,
            eventName: eventName,
            target: eventName,
            body: ""
        )

        let lowercasedEvent = eventName.lowercased()
        let promptTextPresent = firstString(in: json, keys: ["prompt", "prompt_text", "promptText"]) != nil
        let responseTextPresent = firstString(in: json, keys: ["response", "output", "content", "message"]) != nil

        return CodexTelemetryRecord(
            timestamp: timestamp,
            conversationID: conversationID,
            eventName: eventName,
            tokenCount: totalTokens,
            isPrompt: lowercasedEvent.contains("prompt") || lowercasedEvent.contains("user") || lowercasedEvent.contains("conversation.start") || promptTextPresent,
            isResponse: lowercasedEvent.contains("response") || lowercasedEvent.contains("assistant") || lowercasedEvent.contains("completion") || responseTextPresent,
            isToolEvent: lowercasedEvent.contains("tool"),
            isApprovalEvent: lowercasedEvent.contains("approval") || lowercasedEvent.contains("permission")
        )
    }

    private func parseSessionTokenCountRecord(from json: Any, timestamp: Date) -> CodexTelemetryRecord? {
        guard let dict = json as? [String: Any],
              let payload = dict["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String,
              payloadType == "token_count" else {
            return nil
        }

        let info = payload["info"] as? [String: Any]
        let usage = (info?["last_token_usage"] as? [String: Any])
            ?? (info?["total_token_usage"] as? [String: Any])
        let tokens = usage.map(tokenTotal(from:)) ?? 0
        let conversationID = firstString(
            in: json,
            keys: ["thread_id", "threadId", "conversation_id", "conversationId", "session_id", "sessionId"]
        )

        return CodexTelemetryRecord(
            timestamp: timestamp,
            conversationID: conversationID,
            eventName: payloadType,
            tokenCount: tokens,
            isPrompt: false,
            isResponse: true,
            isToolEvent: false,
            isApprovalEvent: false
        )
    }

    private func embeddedJSONObject(from text: String) -> Any? {
        guard let startIndex = text.firstIndex(of: "{"),
              let endIndex = text.lastIndex(of: "}") else {
            return nil
        }

        let jsonSubstring = text[startIndex...endIndex]
        guard let data = jsonSubstring.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func tokenEstimate(from json: Any?, eventName: String, target: String, body: String) -> Double {
        let eventText = "\(eventName) \(target) \(body)".lowercased()

        if let json,
           let usage = responseUsageDictionary(in: json, eventText: eventText) {
            return tokenTotal(from: usage)
        }

        guard eventText.contains("response") || eventText.contains("completion") else {
            return 0
        }

        if let total = usageNumber(in: body, key: "total_tokens") {
            return total
        }

        let input = usageNumber(in: body, key: "input_tokens")
            ?? usageNumber(in: body, key: "prompt_tokens")
            ?? usageNumber(in: body, key: "cached_input_tokens")
        let output = usageNumber(in: body, key: "output_tokens")
            ?? usageNumber(in: body, key: "completion_tokens")

        if let input, let output { return input + output }
        if let input { return input }
        if let output { return output }
        return 0
    }

    private func responseUsageDictionary(in json: Any, eventText: String) -> [String: Any]? {
        guard let dict = json as? [String: Any] else { return nil }

        if let response = dict["response"] as? [String: Any],
           let usage = response["usage"] as? [String: Any] {
            return usage
        }
        if let usage = dict["usage"] as? [String: Any] {
            return usage
        }

        for key in ["data", "result", "payload", "item", "message"] {
            if let nested = dict[key] as? [String: Any],
               let usage = responseUsageDictionary(in: nested, eventText: eventText) {
                return usage
            }
        }

        if eventText.contains("response") || eventText.contains("completion") {
            for value in dict.values {
                if let nested = value as? [String: Any],
                   let usage = responseUsageDictionary(in: nested, eventText: eventText) {
                    return usage
                }
            }
        }

        return nil
    }

    private func tokenTotal(from usage: [String: Any]) -> Double {
        if let total = exactNumber(in: usage, key: "total_tokens"), total > 0 {
            return total
        }
        if let total = exactNumber(in: usage, key: "totalTokens"), total > 0 {
            return total
        }

        let input = exactNumber(in: usage, key: "input_tokens")
            ?? exactNumber(in: usage, key: "prompt_tokens")
            ?? exactNumber(in: usage, key: "cached_input_tokens")
        let output = exactNumber(in: usage, key: "output_tokens")
            ?? exactNumber(in: usage, key: "completion_tokens")

        if let input, let output { return input + output }
        if let input { return input }
        if let output { return output }
        return 0
    }

    private func exactNumber(in dict: [String: Any], key: String) -> Double? {
        if let value = dict[key] as? Double { return value }
        if let value = dict[key] as? Int { return Double(value) }
        if let value = dict[key] as? NSNumber { return value.doubleValue }
        if let value = dict[key] as? String, let parsed = Double(value) { return parsed }
        return nil
    }

    private func usageNumber(in body: String, key: String) -> Double? {
        let pattern = #""usage"\s*:\s*\{[^}]*""# + NSRegularExpression.escapedPattern(for: key) + #""\s*:\s*([0-9]+(?:\.[0-9]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(body.startIndex..., in: body)
        guard let match = regex.firstMatch(in: body, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: body),
              let value = Double(body[captureRange]) else {
            return nil
        }

        return value
    }

    private func extractEventName(from json: Any?, target: String, body: String) -> String {
        if let json,
           let eventName = firstString(in: json, keys: ["event", "name", "type", "kind", "metric"]) {
            return eventName
        }
        if !target.isEmpty {
            return target
        }
        if let delimiterIndex = body.firstIndex(of: ":") {
            let prefix = body[body.startIndex..<delimiterIndex]
            return prefix.trimmingCharacters(in: .whitespaces)
        }
        return "codex.log"
    }

    private func classifyPrompt(target: String, body: String) -> Bool {
        let text = "\(target) \(body)".lowercased()
        return text.contains("submission_dispatch")
            || text.contains("user_input")
            || text.contains("prompt")
            || text.contains("run_sampling_request")
    }

    private func classifyResponse(target: String, body: String) -> Bool {
        let text = "\(target) \(body)".lowercased()
        return text.contains("response.completed")
            || text.contains("response.created")
            || text.contains("response.in_progress")
            || text.contains("responses_websocket")
    }

    private func classifyToolEvent(target: String, body: String) -> Bool {
        let text = "\(target) \(body)".lowercased()
        return text.contains("tool")
            || text.contains("exec_command")
            || text.contains("list_tools")
            || text.contains("function")
    }

    private func classifyApprovalEvent(target: String, body: String) -> Bool {
        let text = "\(target) \(body)".lowercased()
        return text.contains("approval")
            || text.contains("exec_policy")
            || text.contains("policy")
            || text.contains("permission")
    }

    private func stringValue(forColumn index: Int32, statement: OpaquePointer?) -> String? {
        guard let statement, let textPointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: textPointer)
    }

    private func firstString(in json: Any, keys: [String]) -> String? {
        guard let dict = json as? [String: Any] else { return nil }

        for key in keys {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }

        for value in dict.values {
            if let nested = firstString(in: value, keys: keys) {
                return nested
            }
        }

        return nil
    }

    private func firstDate(in json: Any, keys: [String]) -> Date? {
        guard let raw = firstString(in: json, keys: keys) else {
            return nil
        }

        if let date = Self.iso8601WithFractionalSeconds.date(from: raw) {
            return date
        }

        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        if let date = fallback.date(from: raw) {
            return date
        }

        if let epoch = Double(raw) {
            return Date(timeIntervalSince1970: epoch)
        }

        return nil
    }

    private func fileModificationDate(for url: URL) -> Date {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }

    private func fileSize(for url: URL) -> Int {
        guard let value = try? fileManager.attributesOfItem(atPath: url.path)[.size] else {
            return 0
        }
        if let size = value as? Int { return size }
        if let size = value as? NSNumber { return size.intValue }
        return 0
    }

    private func isSessionTelemetryURL(_ url: URL) -> Bool {
        url.pathExtension == "jsonl" && url.pathComponents.contains("sessions")
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    private func stableEventID(for record: CodexTelemetryRecord) -> UUID {
        let timestamp = String(format: "%.9f", record.timestamp.timeIntervalSince1970)
        let key = [
            timestamp,
            record.conversationID ?? "",
            record.eventName,
            String(format: "%.3f", record.tokenCount),
            record.isPrompt ? "prompt" : "",
            record.isResponse ? "response" : "",
            record.isToolEvent ? "tool" : "",
            record.isApprovalEvent ? "approval" : ""
        ].joined(separator: "|")

        let digest = SHA256.hash(data: Data(key.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct CodexTelemetryFileInfo {
    let url: URL
    let modificationDate: Date
    let fileSize: Int
}

private struct CodexTelemetryRecord {
    let timestamp: Date
    let conversationID: String?
    let eventName: String
    let tokenCount: Double
    let isPrompt: Bool
    let isResponse: Bool
    let isToolEvent: Bool
    let isApprovalEvent: Bool
}
