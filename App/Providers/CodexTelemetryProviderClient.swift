import Foundation
import CryptoKit
import SQLite3

/// Reads local Codex telemetry and metadata.
/// This is a no-API, user-controlled source.
public struct CodexTelemetryProviderClient: ProviderClient {
    public let providerID: ProviderID = .codexTelemetry

    private let fileManager: FileManager
    // 30 days: matches the heatmap window so historical activity remains
    // visible even after a multi-day quiet period on Codex CLI.
    private let sessionScanLookback: TimeInterval = 30 * 24 * 60 * 60
    private let maxSessionTelemetryFiles = 4
    private let maxSessionTelemetryBytes = 1 * 1024 * 1024
    private let maxTextTelemetryBytes = 8 * 1024 * 1024
    private let sqliteTelemetryLookback: TimeInterval = 35 * 24 * 60 * 60
    private let maxSQLiteEventsPerHeatmapBucket = 8

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func fetchSnapshot(credentials: ProviderCredential?) async throws -> QuotaSnapshot {
        let rootURL = resolvedTelemetryRootURL(credentials: credentials)
        let bookmarkData = telemetryBookmarkData(from: credentials)

        print("[CodexTelemetry] Reading local Codex logs from: \(rootURL.path)")

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var accessURL = rootURL
                var didStartAccessing = false

                if let bookmarkData,
                   let bookmarkedURL = Self.resolvedSecurityScopedURL(from: bookmarkData) {
                    accessURL = bookmarkedURL
                    didStartAccessing = accessURL.startAccessingSecurityScopedResource()
                }

                defer {
                    if didStartAccessing {
                        accessURL.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    let snapshot = try self.loadSnapshot(rootURL: accessURL)
                    continuation.resume(returning: snapshot)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func loadSnapshot(rootURL: URL) throws -> QuotaSnapshot {
        let now = Date()
        let dayStart = now.addingTimeInterval(-24 * 60 * 60)
        let weekStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let monthStart = now.addingTimeInterval(-30 * 24 * 60 * 60)

        let primaryScanFiles = discoverTelemetryURLs(in: rootURL)
        // Codex CLI's `logs_2.sqlite` keeps only a short telemetry tail
        // (we've observed ~10 days), but session JSONL files at
        // `sessions/YYYY/MM/DD/rollout-*.jsonl` extend much further
        // back. The primary scan honours `prefix(2)` for perf when
        // SQLite is present, so older days never get scanned. This
        // targeted backfill picks up session files only for dates that
        // are *missing* from the persisted snapshot — typically a
        // one-shot expense on first launch after the fix, then quiet
        // forever because the persisted snapshot retains the buckets.
        let backfillFiles = backfillSessionTelemetryURLs(in: rootURL, now: now)
        let scanFiles = primaryScanFiles + backfillFiles
        if backfillFiles.isEmpty {
            print("[CodexTelemetry] Scanning \(scanFiles.count) telemetry sources")
        } else {
            print("[CodexTelemetry] Scanning \(scanFiles.count) telemetry sources (\(backfillFiles.count) historical backfill)")
        }

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
                    sessionEvents += record.eventCount
                }
                if record.timestamp >= weekStart {
                    weekEvents += record.eventCount
                }
                if record.timestamp >= monthStart {
                    monthEvents += record.eventCount
                }

                if record.timestamp >= dayStart {
                    tokenCount24h += record.tokenCount
                    if record.isPrompt { promptEvents24h += record.eventCount }
                    if record.isResponse { responseEvents24h += record.eventCount }
                    if record.isToolEvent { toolEvents24h += record.eventCount }
                    if record.isApprovalEvent { approvalEvents24h += record.eventCount }
                }

                if record.timestamp >= weekStart {
                    tokenCount7d += record.tokenCount
                }

                if let cid = record.conversationID {
                    conversationIDs.insert(cid)
                }

                if record.timestamp > lastActivity {
                    lastActivity = record.timestamp
                }
            }
        }

        // Previous behavior threw `notConfigured` whenever the lookback window
        // contained no recent activity, which made Codex flicker off the
        // dashboard and heatmap during quiet periods. We now return a valid
        // (possibly empty-events) snapshot so the provider stays configured,
        // and the heatmap retains any older cached events.

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

        let signals: [QuotaSignal] = []

        // AGBench's unified `usage.json` records every run including
        // Codex CLI invocations. Adding those events here means a user
        // who drives Codex through TaskWraith sees the corresponding
        // squares on the heatmap even if the underlying telemetry files
        // have rotated out of Codex's own SQLite/session retention.
        // No-op when the user hasn't granted the AGBench bookmark.
        let agbenchEvents = AGBenchUsageReader.loadEvents(forProviderKey: "codex")
        let mergedEvents = events + agbenchEvents

        let cappedEvents = cappedHeatmapEvents(from: mergedEvents, now: now)
        print("[CodexTelemetry] Loaded \(events.count) telemetry events + \(agbenchEvents.count) AGBench events, retaining \(cappedEvents.count) heatmap events")

        return QuotaSnapshot(
            providerID: .codexTelemetry,
            displayName: "Codex Telemetry",
            planName: "Local Logs",
            windows: windows,
            stats: stats,
            balances: [],
            signals: signals,
            events: cappedEvents,
            fetchState: .success,
            fetchedAt: lastActivity > .distantPast ? lastActivity : now
        )
    }

    private func discoverTelemetryURLs(in root: URL) -> [CodexTelemetryFileInfo] {
        if isRegularFile(root) {
            return [
                CodexTelemetryFileInfo(
                    url: root,
                    modificationDate: fileModificationDate(for: root),
                    fileSize: fileSize(for: root)
                )
            ]
        }

        let candidateURLs = telemetryCandidateURLs(in: root)
        let existing = candidateURLs.compactMap { url -> CodexTelemetryFileInfo? in
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return CodexTelemetryFileInfo(
                url: url,
                modificationDate: fileModificationDate(for: url),
                fileSize: fileSize(for: url)
            )
        }

        let hasSQLite = existing.contains { $0.url.lastPathComponent == "logs_2.sqlite" }
        let sessionFiles = hasSQLite ? Array(sessionTelemetryURLs(in: root).prefix(2)) : sessionTelemetryURLs(in: root)

        return (existing + sessionFiles).sorted { lhs, rhs in
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

    /// Cap how much we'll backfill per fetch. Each session file reads up
    /// to `maxSessionTelemetryBytes` (1 MB) so 80 files ≈ 80 MB tops —
    /// large enough to clear a typical multi-week gap in 1-2 fetches,
    /// small enough to keep the first post-deploy refresh under a few
    /// seconds. Once the persisted snapshot has events for every day in
    /// the 30-day window, this returns [] and goes quiet.
    private static let maxBackfillFilesPerFetch = 80

    /// Returns session JSONL files for dates that have NO events in the
    /// currently-persisted Codex snapshot, so we can fill the gap left
    /// by Codex CLI's short SQLite retention. Ordered newest-first so
    /// the most recently missed days backfill first.
    ///
    /// Why "missing dates" rather than always scanning everything: the
    /// 30-day session-file pool can be 7+ GB on heavy users. Reading
    /// all of it on every refresh is unworkable. But dates that already
    /// have events in the snapshot don't need re-scanning — their
    /// buckets are durably persisted by `SyncCoordinator`'s history
    /// merge. So after a one-shot backfill, this stays a no-op.
    private func backfillSessionTelemetryURLs(in root: URL, now: Date) -> [CodexTelemetryFileInfo] {
        let sessionsRoot = root.lastPathComponent == "sessions"
            ? root
            : root.appendingPathComponent("sessions")
        guard isDirectory(sessionsRoot) else { return [] }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        // Days already covered by the persisted snapshot — those don't
        // need re-scanning.
        let datesWithEvents: Set<Date> = {
            guard let previous = QuotaSnapshotStore.shared.loadSnapshots()
                .first(where: { $0.providerID == .codexTelemetry }) else {
                return []
            }
            return Set(previous.events.map { calendar.startOfDay(for: $0.timestamp) })
        }()

        // Walk the 30-day window newest-first, collecting session files
        // for each missing day. Stop once we hit the per-fetch file
        // budget so a heavy backfill doesn't blow out the fetch timeout.
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        dateFormatter.dateFormat = "yyyy/MM/dd"
        dateFormatter.timeZone = calendar.timeZone

        var collected: [CodexTelemetryFileInfo] = []

        for daysAgo in 0..<30 {
            guard collected.count < Self.maxBackfillFilesPerFetch,
                  let targetDate = calendar.date(byAdding: .day, value: -daysAgo, to: today) else {
                continue
            }
            if datesWithEvents.contains(targetDate) { continue }

            let folderPath = dateFormatter.string(from: targetDate)
            let folderURL = sessionsRoot.appendingPathComponent(folderPath)
            guard isDirectory(folderURL) else { continue }

            let folderContents = (try? fileManager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            )) ?? []

            for url in folderContents where url.pathExtension == "jsonl" {
                if collected.count >= Self.maxBackfillFilesPerFetch { break }
                guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
                ), values.isRegularFile == true else { continue }
                collected.append(
                    CodexTelemetryFileInfo(
                        url: url,
                        modificationDate: values.contentModificationDate ?? fileModificationDate(for: url),
                        fileSize: values.fileSize ?? fileSize(for: url)
                    )
                )
            }
        }

        return collected
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

        guard let db = openReadOnlySQLiteDatabase(at: url) else {
            return []
        }
        defer { sqlite3_close(db) }

        let cutoff = Int64(Date().addingTimeInterval(-sqliteTelemetryLookback).timeIntervalSince1970)
        let query = """
        SELECT (ts / 7200) * 7200 AS bucket_ts, COUNT(*) AS event_count
        FROM logs
        WHERE ts >= ?
        GROUP BY bucket_ts
        ORDER BY bucket_ts ASC;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cutoff)

        var records: [CodexTelemetryRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let bucketTimestamp = sqlite3_column_int64(statement, 0)
            let eventCount = max(1, sqlite3_column_int64(statement, 1))
            let markerCount = min(maxSQLiteEventsPerHeatmapBucket, max(1, Int(ceil(log2(Double(eventCount) + 1)))))
            let countPerMarker = Double(eventCount) / Double(markerCount)
            let spacing = 7200.0 / Double(markerCount + 1)

            for index in 0..<markerCount {
                records.append(
                    CodexTelemetryRecord(
                        timestamp: Date(timeIntervalSince1970: Double(bucketTimestamp) + spacing * Double(index + 1)),
                        conversationID: nil,
                        eventName: "codex.sqlite.bucket.\(bucketTimestamp).\(index)",
                        tokenCount: 0,
                        isPrompt: false,
                        isResponse: false,
                        isToolEvent: false,
                        isApprovalEvent: false,
                        eventCount: countPerMarker
                    )
                )
            }
        }

        return records
    }

    private func sqliteEventName(target: String, body: String) -> String {
        if !target.isEmpty {
            return target
        }

        if let delimiterIndex = body.firstIndex(of: ":") {
            let prefix = body[body.startIndex..<delimiterIndex]
            return prefix.trimmingCharacters(in: .whitespaces)
        }

        return "codex.sqlite"
    }

    private func sqliteClassificationSample(target: String, body: String) -> String {
        let prefix = body.prefix(4096)
        return "\(target) \(prefix)".lowercased()
    }

    private func fastSQLiteTokenEstimate(target: String, body: String) -> Double {
        let lowerTarget = target.lowercased()
        guard lowerTarget.contains("response")
                || lowerTarget.contains("completion")
                || body.contains(#""usage""#)
                || body.contains("total_tokens")
                || body.contains("input_tokens")
                || body.contains("output_tokens") else {
            return 0
        }

        if let total = fastJSONNumber(in: body, key: "total_tokens")
            ?? fastJSONNumber(in: body, key: "totalTokens"),
           total > 0 {
            return total
        }

        let input = fastJSONNumber(in: body, key: "input_tokens")
            ?? fastJSONNumber(in: body, key: "prompt_tokens")
            ?? fastJSONNumber(in: body, key: "cached_input_tokens")
        let output = fastJSONNumber(in: body, key: "output_tokens")
            ?? fastJSONNumber(in: body, key: "completion_tokens")

        if let input, let output { return input + output }
        return input ?? output ?? 0
    }

    private func fastJSONNumber(in text: String, key: String) -> Double? {
        let quotedKey = "\"\(key)\""
        guard let keyRange = text.range(of: quotedKey, options: [.caseInsensitive]) else {
            return nil
        }

        let afterKey = text[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else {
            return nil
        }

        var index = afterKey.index(after: colon)
        while index < afterKey.endIndex,
              afterKey[index].isWhitespace || afterKey[index] == "\"" {
            index = afterKey.index(after: index)
        }

        let start = index
        while index < afterKey.endIndex,
              afterKey[index].isNumber || afterKey[index] == "." {
            index = afterKey.index(after: index)
        }

        guard start < index else { return nil }
        return Double(afterKey[start..<index])
    }

    private func openReadOnlySQLiteDatabase(at url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db {
            return db
        }
        if let db {
            sqlite3_close(db)
        }

        db = nil
        let uri = url.absoluteString + "?mode=ro&immutable=1"
        if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db {
            return db
        }
        if let db {
            sqlite3_close(db)
        }
        return nil
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
        let isPrompt = lowercasedEvent.contains("prompt")
            || lowercasedEvent.contains("user")
            || lowercasedEvent.contains("conversation.start")
        let isResponse = lowercasedEvent.contains("response")
            || lowercasedEvent.contains("assistant")
            || lowercasedEvent.contains("completion")
        let isToolEvent = lowercasedEvent.contains("tool")
        let isApprovalEvent = lowercasedEvent.contains("approval")
            || lowercasedEvent.contains("permission")

        let promptTextPresent = firstString(in: json, keys: ["prompt", "prompt_text", "promptText"]) != nil
        let responseTextPresent = firstString(in: json, keys: ["response", "output", "content", "message"]) != nil

        return CodexTelemetryRecord(
            timestamp: timestamp,
            conversationID: conversationID,
            eventName: eventName,
            tokenCount: totalTokens,
            isPrompt: isPrompt || promptTextPresent,
            isResponse: isResponse || responseTextPresent,
            isToolEvent: isToolEvent,
            isApprovalEvent: isApprovalEvent,
            eventCount: 1
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
            isApprovalEvent: false,
            eventCount: 1
        )
    }

    private func cappedHeatmapEvents(from events: [UsageEvent], now: Date) -> [UsageEvent] {
        let cutoff = now.addingTimeInterval(-35 * 24 * 60 * 60)
        var retained: [UsageEvent] = []
        var bucketCounts: [CodexTelemetryBucketKey: Int] = [:]
        let calendar = Calendar.current

        for event in events.sorted(by: { $0.timestamp > $1.timestamp }) where event.timestamp >= cutoff {
            let key = CodexTelemetryBucketKey(timestamp: event.timestamp, calendar: calendar)
            guard bucketCounts[key, default: 0] < maxSQLiteEventsPerHeatmapBucket else {
                continue
            }
            bucketCounts[key, default: 0] += 1
            retained.append(event)
        }

        return retained.sorted { $0.timestamp > $1.timestamp }
    }

    private func embeddedJSONObject(from text: String) -> Any? {
        guard let startIndex = text.firstIndex(of: "{"),
              let endIndex = text.lastIndex(of: "}")
        else {
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

        if let input, let output {
            return input + output
        }
        if let input {
            return input
        }
        if let output {
            return output
        }

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

        if let input, let output {
            return input + output
        }
        if let input {
            return input
        }
        if let output {
            return output
        }

        return 0
    }

    private func exactNumber(in dict: [String: Any], key: String) -> Double? {
        if let value = dict[key] as? Double {
            return value
        }
        if let value = dict[key] as? Int {
            return Double(value)
        }
        if let value = dict[key] as? NSNumber {
            return value.doubleValue
        }
        if let value = dict[key] as? String, let parsed = Double(value) {
            return parsed
        }
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
        classifyPrompt(lowercasedText: "\(target) \(body)".lowercased())
    }

    private func classifyResponse(target: String, body: String) -> Bool {
        classifyResponse(lowercasedText: "\(target) \(body)".lowercased())
    }

    private func classifyToolEvent(target: String, body: String) -> Bool {
        classifyToolEvent(lowercasedText: "\(target) \(body)".lowercased())
    }

    private func classifyApprovalEvent(target: String, body: String) -> Bool {
        classifyApprovalEvent(lowercasedText: "\(target) \(body)".lowercased())
    }

    private func classifyPrompt(lowercasedText text: String) -> Bool {
        text.contains("submission_dispatch")
            || text.contains("user_input")
            || text.contains("prompt")
            || text.contains("run_sampling_request")
    }

    private func classifyResponse(lowercasedText text: String) -> Bool {
        text.contains("response.completed")
            || text.contains("response.created")
            || text.contains("response.in_progress")
            || text.contains("responses_websocket")
    }

    private func classifyToolEvent(lowercasedText text: String) -> Bool {
        text.contains("tool")
            || text.contains("exec_command")
            || text.contains("list_tools")
            || text.contains("function")
    }

    private func classifyApprovalEvent(lowercasedText text: String) -> Bool {
        text.contains("approval")
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

    private func firstNumber(in text: String, keys: [String]) -> Double? {
        for key in keys {
            let pattern = #"\#(key)\s*[:=]\s*([0-9]+(?:\.[0-9]+)?)"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: text),
                  let value = Double(text[captureRange])
            else {
                continue
            }

            return value
        }

        return nil
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
        if let size = value as? Int {
            return size
        }
        if let size = value as? NSNumber {
            return size.intValue
        }
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

    private func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return !isDirectory.boolValue
    }

    private func resolvedTelemetryRootURL(credentials: ProviderCredential?) -> URL {
        if let path = credentials?.customEndpoint, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        #if os(macOS)
        // `homeDirectoryForCurrentUser` returns the sandbox container in a
        // sandboxed app, so we strip the container suffix from NSHomeDirectory
        // to reach the real `~`. The actual file read still requires a
        // security-scoped bookmark — but this gives auto-discovery and
        // bookmark resolution a sane default to fall back on.
        let homePath = NSHomeDirectory()
        let realHomePath: String
        if let containerRange = homePath.range(of: "/Library/Containers/") {
            realHomePath = String(homePath[..<containerRange.lowerBound])
        } else {
            realHomePath = homePath
        }
        return URL(fileURLWithPath: realHomePath).appendingPathComponent(".codex")
        #else
        return FileManager.default.temporaryDirectory // Fallback for iOS
        #endif
    }

    private func telemetryBookmarkData(from credentials: ProviderCredential?) -> Data? {
        if let bookmarkData = credentials?.bookmarkData {
            return bookmarkData
        }

        guard let encoded = credentials?.extraFields?["bookmarkData"] else {
            return nil
        }
        return Data(base64Encoded: encoded)
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

    private static func resolvedSecurityScopedURL(from data: Data) -> URL? {
        var isStale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = .withSecurityScope
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif

        guard let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        return url
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
    let eventCount: Double
}

private struct CodexTelemetryBucketKey: Hashable {
    let dayStart: Date
    let row: Int

    init(timestamp: Date, calendar: Calendar) {
        dayStart = calendar.startOfDay(for: timestamp)
        row = calendar.component(.hour, from: timestamp) / 2
    }
}
