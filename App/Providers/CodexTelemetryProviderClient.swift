import Foundation
import CryptoKit
import SQLite3

/// Reads local Codex telemetry and metadata.
/// This is a no-API, user-controlled source.
public struct CodexTelemetryProviderClient: ProviderClient {
    public let providerID: ProviderID = .codexTelemetry

    private let fileManager: FileManager
    private let previousEvents: @Sendable () -> [UsageEvent]
    private let parseCache: TelemetryParseCache
    private let supplementalEvents: @Sendable () -> [UsageEvent]
    // 30 days: matches the heatmap window so historical activity remains
    // visible even after a multi-day quiet period on Codex CLI.
    private let sessionScanLookback: TimeInterval = 30 * 24 * 60 * 60
    // A heavy day spans ~200 session files, so the previous cap of 4 could not
    // see a day's usage at all. Matches the file budget the backfill path
    // already declares acceptable below; the cost of raising both this and
    // `maxSessionTelemetryBytes` is carried by TelemetryParseCache, which makes
    // re-scanning an unchanged session free.
    private let maxSessionTelemetryFiles = 80
    // Sessions are tail-read. At 1 MB a busy day's rollouts surrendered only
    // their last few turns — measured against this machine's logs, 1 MB
    // recovered 12% of a day's tokens where 8 MB recovers 93%, because the
    // per-turn deltas that make up the bulk of a session sit further back in
    // the file. Matches `maxTextTelemetryBytes`.
    private let maxSessionTelemetryBytes = 8 * 1024 * 1024
    private let maxTextTelemetryBytes = 8 * 1024 * 1024
    private let maxEventsPerHeatmapBucket = 8
    private static let parseCacheProvider = "codexTelemetry"

    public init(fileManager: FileManager = .default) {
        self.init(
            fileManager: fileManager,
            previousEvents: {
                QuotaSnapshotStore.shared.loadSnapshots()
                    .first { $0.providerID == .codexTelemetry }?.events ?? []
            },
            parseCache: .shared,
            supplementalEvents: { AGBenchUsageReader.loadEvents(forProviderKey: "codex") }
        )
    }

    init(
        fileManager: FileManager,
        previousEvents: @escaping @Sendable () -> [UsageEvent],
        parseCache: TelemetryParseCache,
        supplementalEvents: @escaping @Sendable () -> [UsageEvent]
    ) {
        self.fileManager = fileManager
        self.previousEvents = previousEvents
        self.parseCache = parseCache
        self.supplementalEvents = supplementalEvents
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
        // back, and the primary scan is bounded by
        // `maxSessionTelemetryFiles`. This targeted backfill picks up
        // session files only for dates that are *missing* from the
        // persisted snapshot — typically a one-shot expense on first
        // launch, then quiet forever because the persisted snapshot
        // retains the buckets.
        let backfillFiles = backfillSessionTelemetryURLs(in: rootURL, now: now)
        // The two lists overlap whenever a recent day is also a missing
        // day, and parsing one file twice counts its tokens twice.
        var seenScanPaths = Set<String>()
        let scanFiles = (primaryScanFiles + backfillFiles).filter {
            seenScanPaths.insert($0.url.path).inserted
        }
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

        // Session rollouts are append-only and mostly cold, so parsing them on
        // every refresh was the dominant cost of a scan. Cache per file and
        // only pay for the ones that changed. Bounded to a few multiples of the
        // primary scan so the store stays small; backfill's historical files
        // are read once and would never be looked up again.
        parseCache.prune(
            provider: Self.parseCacheProvider,
            keepingNewest: maxSessionTelemetryFiles * 3
        )

        for telemetryInfo in scanFiles {
            let parsed = cachedTelemetryRecords(for: telemetryInfo)
            guard !parsed.records.isEmpty else { continue }

            for (record, eventID) in zip(parsed.records, parsed.eventIDs) {
                guard record.timestamp <= now else { continue }
                events.append(UsageEvent(
                    id: eventID,
                    timestamp: record.timestamp,
                    tokens: record.tokenCount,
                    model: "Codex",
                    type: record.tokenCount > 0 ? .telemetry : .activity
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

        // No-op unless this scan actually parsed something new.
        parseCache.persist()

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
        let agbenchEvents = supplementalEvents()
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

        // Session JSONL used to collapse to `prefix(2)` whenever logs_2.sqlite
        // was present, on the assumption SQLite already covered recent
        // activity. It doesn't: the SQLite path emits activity markers with
        // `tokenCount: 0`, so deferring to it meant Codex tokens were read from
        // two files on a day that spans hundreds.
        let sessionFiles = sessionTelemetryURLs(in: root)

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
        // need re-scanning. Coverage means TOKENS, not merely events: the
        // SQLite path contributes activity markers carrying `tokenCount: 0`,
        // so counting any event as coverage let a zero-token marker mark a day
        // as done and permanently suppress the backfill that would have found
        // that day's actual usage.
        let datesWithEvents = Set(
            previousEvents()
                .filter { ($0.tokens ?? 0) > 0 }
                .map { calendar.startOfDay(for: $0.timestamp) }
        )

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

    /// Cache-aware wrapper around `readTelemetryRecords`. Only session JSONL is
    /// cached: `logs_2.sqlite` and the rolling text logs change on virtually
    /// every refresh, so caching those would only churn the store.
    private func cachedTelemetryRecords(for info: CodexTelemetryFileInfo) -> CodexParsedTelemetryFile {
        guard isSessionTelemetryURL(info.url) else {
            return CodexParsedTelemetryFile(records: (try? readTelemetryRecords(from: info.url)) ?? [])
        }

        if let cached = parseCache.value(
            CodexParsedTelemetryFile.self,
            provider: Self.parseCacheProvider,
            path: info.url.path,
            modifiedAt: info.modificationDate,
            size: info.fileSize
        ) {
            return cached
        }

        let parsed = CodexParsedTelemetryFile(records: (try? readTelemetryRecords(from: info.url)) ?? [])
        parseCache.store(
            parsed,
            provider: Self.parseCacheProvider,
            path: info.url.path,
            modifiedAt: info.modificationDate,
            size: info.fileSize
        )
        return parsed
    }

    private func readTelemetryRecords(from url: URL) throws -> [CodexTelemetryRecord] {
        if url.lastPathComponent == "logs_2.sqlite" {
            // This database is a diagnostic log, not a record of model usage.
            // Configuration reloads, polling and other idle messages must not
            // become synthetic heatmap events. Use session records instead.
            return []
        }

        let data = try telemetryTextData(from: url)
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }

        var records: [CodexTelemetryRecord] = []
        // Per-file running total, so token_count events can be reduced to
        // per-turn deltas. Nil until the first one is seen.
        var previousCumulative: Double?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: lineData) else { continue }
            if let record = parseRecord(from: json, previousCumulative: &previousCumulative) {
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

    private func parseRecord(from json: Any, previousCumulative: inout Double?) -> CodexTelemetryRecord? {
        guard let dict = json as? [String: Any],
              let timestamp = firstDate(in: dict, keys: ["timestamp", "time", "created_at", "createdAt", "date"]) else {
            return nil
        }

        let envelopeType = dict["type"] as? String ?? ""
        let payload = dict["payload"] as? [String: Any] ?? [:]
        let payloadType = payload["type"] as? String ?? ""

        // A repeated or empty token_count is not another activity event. Do
        // not fall through to a generic timestamp-based record when it is nil.
        if envelopeType == "event_msg", payloadType == "token_count" {
            return parseSessionTokenCountRecord(
                from: dict,
                timestamp: timestamp,
                previousCumulative: &previousCumulative
            )
        }

        var isPrompt = false
        var isResponse = false
        var isToolEvent = false
        var tokens = 0.0
        let eventName: String

        switch envelopeType {
        case "event_msg":
            eventName = "\(envelopeType).\(payloadType)"
            switch payloadType {
            case "user_message":
                isPrompt = true
            case "agent_message":
                isResponse = true
            case "task_started", "task_complete":
                break
            default:
                return nil
            }

        case "response_item":
            eventName = "\(envelopeType).\(payloadType)"
            switch payloadType {
            case "message":
                switch payload["role"] as? String {
                case "user": isPrompt = true
                case "assistant": isResponse = true
                default: return nil // Developer/system context is not usage.
                }
            case "reasoning", "agent_message":
                isResponse = true
            case "function_call", "function_call_output",
                 "custom_tool_call", "custom_tool_call_output":
                isToolEvent = true
            default:
                return nil
            }

        default:
            // Support structured response logs with explicit usage, while
            // rejecting session metadata, world-state updates, diagnostics and
            // the separate token_usage_record copy of session token counts.
            eventName = ["event", "name", "type", "kind", "metric"]
                .compactMap { dict[$0] as? String }.first ?? ""
            let responseEvents: Set<String> = [
                "response", "response.completed", "completion",
                "codex.response", "codex.completion"
            ]
            guard responseEvents.contains(eventName.lowercased()) else { return nil }
            tokens = tokenEstimate(from: dict, eventName: eventName, target: eventName, body: "")
            guard tokens.isFinite, tokens > 0 else { return nil }
            isResponse = true
        }

        return CodexTelemetryRecord(
            timestamp: timestamp,
            conversationID: firstString(
                in: dict,
                keys: ["conversation_id", "conversationId", "thread_id", "threadId", "session_id", "sessionId", "chat_id", "chatId"]
            ),
            eventName: eventName,
            tokenCount: tokens,
            isPrompt: isPrompt,
            isResponse: isResponse,
            isToolEvent: isToolEvent,
            isApprovalEvent: false,
            eventCount: 1
        )
    }

    /// Codex reports `total_token_usage` as a CUMULATIVE session running total
    /// and `last_token_usage` as that turn's delta. Two things follow.
    ///
    /// Around 16% of token_count events re-emit an unchanged cumulative total,
    /// so taking every `last_token_usage` at face value counts those turns
    /// twice; and a forked session opens carrying its parent's cumulative
    /// baseline, so its first event's total is not its own spend. Tracking the
    /// advance between consecutive events settles both — no advance means a
    /// repeat, while the first event of a fork is still measured by its own
    /// delta. It also removes the need for the old
    /// `?? total_token_usage` fallback, which billed a whole session's running
    /// total as though it were a single turn.
    private func parseSessionTokenCountRecord(
        from json: Any,
        timestamp: Date,
        previousCumulative: inout Double?
    ) -> CodexTelemetryRecord? {
        guard let dict = json as? [String: Any],
              let payload = dict["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String,
              payloadType == "token_count" else {
            return nil
        }

        let info = payload["info"] as? [String: Any]
        let cumulative = (info?["total_token_usage"] as? [String: Any]).map(tokenTotal(from:)) ?? 0
        let advance = previousCumulative.map { cumulative - $0 }
        if cumulative > 0 { previousCumulative = cumulative }

        let tokens: Double
        if let usage = info?["last_token_usage"] as? [String: Any] {
            // A repeat restates a turn already counted.
            if let advance, advance <= 0, cumulative > 0 { return nil }
            tokens = tokenTotal(from: usage)
        } else if let advance, advance > 0 {
            // No per-turn breakdown: the advance is this turn's spend.
            tokens = advance
        } else {
            return nil
        }

        guard tokens.isFinite, tokens > 0 else { return nil }

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

    /// Bounds how many events per 2h bucket reach the persisted snapshot,
    /// without losing the tokens carried by the ones that don't survive.
    ///
    /// The cap exists so a busy hour can't put thousands of events into the
    /// App Group defaults. It used to `continue` past the overflow, which
    /// silently dropped their tokens too — on an hour with hundreds of
    /// token_count events that discarded almost all of the usage it was
    /// supposed to be measuring. Overflow tokens are now folded into the
    /// bucket's last retained event, so the count is bounded while the bucket
    /// total stays exact.
    private func cappedHeatmapEvents(from events: [UsageEvent], now: Date) -> [UsageEvent] {
        let cutoff = now.addingTimeInterval(-35 * 24 * 60 * 60)
        var retained: [UsageEvent] = []
        var indexOfLastRetained: [CodexTelemetryBucketKey: Int] = [:]
        var bucketCounts: [CodexTelemetryBucketKey: Int] = [:]
        let calendar = Calendar.current
        // Newest first, so nearly every event shares the previous one's day:
        // its bounds are computed once per day rather than once per event.
        var day: DateInterval?

        for event in events.sorted(by: { $0.timestamp > $1.timestamp }) where event.timestamp >= cutoff && event.timestamp <= now {
            let isSameDay = day.map { $0.start <= event.timestamp && event.timestamp < $0.end } ?? false
            if !isSameDay {
                day = calendar.dateInterval(of: .day, for: event.timestamp)
            }
            let key = CodexTelemetryBucketKey(
                dayStart: day?.start ?? calendar.startOfDay(for: event.timestamp),
                row: calendar.component(.hour, from: event.timestamp) / 2
            )
            guard bucketCounts[key, default: 0] < maxEventsPerHeatmapBucket else {
                // Bucket is full: carry the tokens over rather than dropping them.
                if let tokens = event.tokens, tokens > 0, let index = indexOfLastRetained[key] {
                    let carrier = retained[index]
                    retained[index] = UsageEvent(
                        id: carrier.id,
                        timestamp: carrier.timestamp,
                        tokens: (carrier.tokens ?? 0) + tokens,
                        model: carrier.model,
                        type: carrier.type
                    )
                }
                continue
            }
            bucketCounts[key, default: 0] += 1
            indexOfLastRetained[key] = retained.count
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

    fileprivate nonisolated static func stableEventID(for record: CodexTelemetryRecord) -> UUID {
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

private struct CodexTelemetryRecord: Codable {
    let timestamp: Date
    let conversationID: String?
    let eventName: String
    let tokenCount: Double
    let isPrompt: Bool
    let isResponse: Bool
    let isToolEvent: Bool
    let isApprovalEvent: Bool
    let eventCount: Double

    // Short keys: these are cached per file and a busy day runs to hundreds of
    // thousands of records.
    enum CodingKeys: String, CodingKey {
        case timestamp = "t"
        case conversationID = "c"
        case eventName = "e"
        case tokenCount = "k"
        case isPrompt = "p"
        case isResponse = "r"
        case isToolEvent = "o"
        case isApprovalEvent = "a"
        case eventCount = "n"
    }
}

/// One file's records with their heatmap event IDs. An ID hashes a formatted
/// key, so deriving them once per parsed file rather than per record on every
/// refresh is what lets an unchanged session cost nothing. Encoded as the bare
/// record array, the parse cache's existing format.
private struct CodexParsedTelemetryFile: Codable {
    let records: [CodexTelemetryRecord]
    let eventIDs: [UUID]

    init(records: [CodexTelemetryRecord]) {
        self.records = records
        eventIDs = records.map(CodexTelemetryProviderClient.stableEventID(for:))
    }

    init(from decoder: Decoder) throws {
        self.init(records: try [CodexTelemetryRecord](from: decoder))
    }

    func encode(to encoder: Encoder) throws {
        try records.encode(to: encoder)
    }
}

private struct CodexTelemetryBucketKey: Hashable {
    let dayStart: Date
    let row: Int
}
