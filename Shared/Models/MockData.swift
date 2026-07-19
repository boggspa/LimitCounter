import Foundation

public enum MockData {

    public static var claudeSnapshot: QuotaSnapshot {
        QuotaSnapshot(
            providerID: .claude,
            displayName: "Claude",
            planName: "Max 5x",
            windows: [
                QuotaWindow(
                    label: "Session",
                    windowKind: .session,
                    used: 0,
                    total: 100,
                    resetDate: Date().addingTimeInterval(1 * 3600 + 18 * 60),
                    unit: "%",
                    subtitle: "Rolling session window"
                ),
                QuotaWindow(
                    label: "Weekly",
                    windowKind: .weekly,
                    used: 65,
                    total: 100,
                    resetDate: Date().addingTimeInterval(29 * 3600 + 18 * 60),
                    unit: "%",
                    subtitle: "Primary weekly quota"
                )
            ],
            stats: [
                QuotaStat(label: "24H Tokens", value: 142_000, unit: "tok"),
                QuotaStat(label: "7D Tokens", value: 921_000, unit: "tok"),
                QuotaStat(label: "30D Tokens", value: 3_400_000, unit: "tok")
            ],
            events: (0..<10).map { i in
                UsageEvent(timestamp: Date().addingTimeInterval(-Double(i) * 3600), tokens: 1000, model: "Claude 3.5 Sonnet")
            },
            fetchState: .success
        )
    }

    public static var codexSnapshot: QuotaSnapshot {
        QuotaSnapshot(
            providerID: .openai,
            displayName: "Codex",
            planName: "Plus",
            windows: [
                QuotaWindow(
                    label: "Weekly",
                    windowKind: .weekly,
                    used: 90,
                    total: 100,
                    resetDate: Date().addingTimeInterval(3 * 3600 + 8 * 60),
                    unit: "%",
                    subtitle: "Rolling weekly allowance"
                ),
                QuotaWindow(
                    label: "GPT-5.3-Codex-Spark Weekly",
                    windowKind: .weekly,
                    used: 18,
                    total: 100,
                    resetDate: Date().addingTimeInterval(2 * 3600 + 22 * 60),
                    unit: "%",
                    subtitle: "7-day usage limit"
                )
            ],
            signals: [
                QuotaSignal(
                    kind: .unexpectedRecovery,
                    title: "Usage window appears refreshed early",
                    message: "Session fell from 82% to 6% about 1h 40m earlier than the prior reset estimate.",
                    severity: .info,
                    confidence: 0.79,
                    windowLabel: "Session",
                    detectedAt: Date().addingTimeInterval(-18 * 60)
                )
            ],
            events: (0..<5).map { i in
                UsageEvent(timestamp: Date().addingTimeInterval(-Double(i) * 7200), tokens: 500, model: "Codex")
            },
            fetchState: .success
        )
    }

    public static var codexTelemetrySnapshot: QuotaSnapshot {
        QuotaSnapshot(
            providerID: .codexTelemetry,
            displayName: "Codex Telemetry",
            planName: "Local logs",
            windows: [
                QuotaWindow(
                    label: "Session Events",
                    windowKind: .session,
                    used: 184,
                    total: nil,
                    resetDate: nil,
                    unit: "events",
                    subtitle: "Most recent 5 hours"
                ),
                QuotaWindow(
                    label: "Weekly Events",
                    windowKind: .weekly,
                    used: 1_322,
                    total: nil,
                    resetDate: nil,
                    unit: "events",
                    subtitle: "Last 7 days"
                )
            ],
            stats: [
                QuotaStat(label: "24H Prompts", value: 41, unit: "msg"),
                QuotaStat(label: "24H Responses", value: 39, unit: "msg"),
                QuotaStat(label: "24H Tool Calls", value: 18, unit: "calls"),
                QuotaStat(label: "24H Tokens", value: 98_240, unit: "tok"),
                QuotaStat(label: "Conversations", value: 11, unit: "threads")
            ],
            fetchState: .success
        )
    }

    public static var openAIAPISnapshot: QuotaSnapshot {
        let calendar = Calendar.current
        let now = Date()
        let dayStart = calendar.startOfDay(for: now)
        let buckets = (0..<18).flatMap { offset -> [UsageAnalyticsBucket] in
            let date = calendar.date(byAdding: .day, value: -offset, to: dayStart) ?? dayStart
            let next = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
            let base = Double((offset % 6) + 2)
            return [
                UsageAnalyticsBucket(
                    startDate: date,
                    endDate: next,
                    model: "gpt-5.5",
                    projectID: "proj_demo",
                    inputTokens: base * 72_000,
                    outputTokens: base * 18_000,
                    cachedInputTokens: base * 24_000,
                    requests: base * 36,
                    source: .officialAPI
                ),
                UsageAnalyticsBucket(
                    startDate: date,
                    endDate: next,
                    model: "gpt-5.4-mini",
                    projectID: "proj_demo",
                    inputTokens: base * 18_000,
                    outputTokens: base * 9_000,
                    requests: base * 22,
                    source: .officialAPI
                ),
                UsageAnalyticsBucket(
                    startDate: date,
                    endDate: next,
                    projectID: "proj_demo",
                    costUSD: base * 1.37,
                    source: .officialAPI,
                    note: "Cost"
                )
            ]
        }

        return QuotaSnapshot(
            providerID: .openaiAPI,
            displayName: "OpenAI API",
            planName: "gpt-5.5",
            windows: [
                QuotaWindow(
                    label: "Requests / Day",
                    windowKind: .daily,
                    used: 1_240,
                    total: 10_000,
                    resetDate: calendar.date(byAdding: .day, value: 1, to: dayStart),
                    unit: "req",
                    subtitle: "gpt-5.5 - Project proj_demo"
                )
            ],
            stats: [
                QuotaStat(label: "Today Tokens", value: 312_000, unit: "tok", subtitle: "Official usage API"),
                QuotaStat(label: "30D Cost", value: 86.42, unit: "$", subtitle: "Official costs API")
            ],
            analyticsBuckets: buckets,
            fetchState: .success
        )
    }

    public static var chatgptSnapshot: QuotaSnapshot {
        QuotaSnapshot(
            providerID: .chatgpt,
            displayName: "ChatGPT",
            planName: "Plus",
            windows: [
                QuotaWindow(
                    label: "24H Active Chats",
                    windowKind: .daily,
                    used: 4,
                    total: nil,
                    resetDate: nil,
                    unit: "chats",
                    subtitle: "Local desktop conversation caches updated in the last 24 hours"
                ),
                QuotaWindow(
                    label: "7D Active Chats",
                    windowKind: .weekly,
                    used: 18,
                    total: nil,
                    resetDate: nil,
                    unit: "chats",
                    subtitle: "Chats updated in the last 7 days"
                ),
                QuotaWindow(
                    label: "30D Active Chats",
                    windowKind: .monthly,
                    used: 53,
                    total: nil,
                    resetDate: nil,
                    unit: "chats",
                    subtitle: "Chats updated in the last 30 days"
                )
            ],
            stats: [
                QuotaStat(label: "Total Chats", value: 81, unit: "chats"),
                QuotaStat(label: "Drafts", value: 6, unit: "drafts"),
                QuotaStat(label: "Projects", value: 2, unit: "projects"),
                QuotaStat(label: "Project Chats", value: 2, unit: "chats"),
                QuotaStat(label: "Local Sends", value: 20, unit: "msg"),
                QuotaStat(label: "Voice Sessions", value: 11, unit: "sessions")
            ],
            fetchState: .success
        )
    }

    public static var windsurfSnapshot: QuotaSnapshot {
        QuotaSnapshot(
            providerID: .windsurf,
            displayName: "Windsurf",
            planName: "Pro",
            windows: [
                QuotaWindow(
                    label: "Monthly Flow Actions",
                    windowKind: .monthly,
                    used: 780,
                    total: 1000,
                    resetDate: Calendar.current.date(from: DateComponents(
                        year: Calendar.current.component(.year, from: Date()),
                        month: Calendar.current.component(.month, from: Date()) + 1,
                        day: 1
                    )),
                    unit: "actions"
                )
            ],
            balances: [
                QuotaBalance(label: "Extra Balance", amount: 12.75, unit: "$")
            ],
            fetchState: .success
        )
    }

    public static var cursorSnapshot: QuotaSnapshot {
        QuotaSnapshot(
            providerID: .cursor,
            displayName: "Cursor",
            planName: "Pro",
            windows: [
                QuotaWindow(
                    label: "Fast Requests",
                    windowKind: .monthly,
                    used: 480,
                    total: 500,
                    resetDate: Calendar.current.date(from: DateComponents(
                        year: Calendar.current.component(.year, from: Date()),
                        month: Calendar.current.component(.month, from: Date()) + 1,
                        day: 1
                    )),
                    unit: "requests",
                    subtitle: "Premium model requests"
                ),
                QuotaWindow(
                    label: "Slow Requests",
                    windowKind: .monthly,
                    used: 1_200,
                    total: nil,
                    resetDate: nil,
                    unit: "requests",
                    subtitle: "Unlimited with Pro plan"
                )
            ],
            fetchState: .success
        )
    }

    public static var kimiSnapshot: QuotaSnapshot {
        QuotaSnapshot(
            providerID: .kimi,
            displayName: "Kimi Code",
            planName: "Moderato",
            windows: [
                QuotaWindow(
                    label: "Weekly",
                    windowKind: .weekly,
                    used: 420,
                    total: 2_000,
                    resetDate: Date().addingTimeInterval(4 * 24 * 3600),
                    unit: "quota",
                    subtitle: "Kimi Code membership quota"
                ),
                QuotaWindow(
                    label: "5H",
                    windowKind: .sliding,
                    used: 61,
                    total: 200,
                    resetDate: Date().addingTimeInterval(2 * 3600 + 30 * 60),
                    unit: "quota",
                    subtitle: "Rolling 5h quota"
                )
            ],
            stats: [
                QuotaStat(label: "Parallel Limit", value: 2, unit: "tasks", subtitle: "Concurrent Kimi Code requests")
            ],
            balances: [
                QuotaBalance(label: "Total Quota", amount: 1_580, unit: "quota", subtitle: "2K total membership quota")
            ],
            fetchState: .success
        )
    }

    public static var allSnapshots: [QuotaSnapshot] {
        [claudeSnapshot, codexSnapshot, openAIAPISnapshot, chatgptSnapshot, codexTelemetrySnapshot, windsurfSnapshot, cursorSnapshot, kimiSnapshot]
    }

    public static var staleSnapshot: QuotaSnapshot {
        QuotaSnapshot(
            providerID: .claude,
            displayName: "Claude",
            planName: "Pro",
            windows: [claudeSnapshot.windows[0]],
            fetchState: .success,
            fetchedAt: Date().addingTimeInterval(-7200)
        )
    }

    public static var errorSnapshot: QuotaSnapshot {
        QuotaSnapshot(
            providerID: .openai,
            displayName: "Codex",
            planName: nil,
            windows: [],
            fetchState: .error
        )
    }

    public static var notConfiguredSnapshot: QuotaSnapshot {
        QuotaSnapshot(
            providerID: .windsurf,
            displayName: "Windsurf",
            planName: nil,
            windows: [],
            fetchState: .notConfigured
        )
    }
}
