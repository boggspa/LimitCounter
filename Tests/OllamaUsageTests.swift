import Foundation

private enum OllamaTestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw OllamaTestError.failure(message) }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw OllamaTestError.failure("\(message): expected \(expected), got \(actual)")
    }
}

private func expectClose(_ actual: Double, _ expected: Double, _ message: String) throws {
    if abs(actual - expected) > 0.000_001 {
        throw OllamaTestError.failure("\(message): expected \(expected), got \(actual)")
    }
}

private func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

private func isolatedDefaults(_ suiteName: String) throws -> UserDefaults {
    try UserDefaults(suiteName: suiteName)
        ?? { throw OllamaTestError.failure("Could not create isolated defaults") }()
}

private func parseOllama(_ html: String, fetchedAt: Date, defaults: UserDefaults) throws -> QuotaSnapshot {
    try OllamaProviderClient().parseOllamaSettingsHTML(html, fetchedAt: fetchedAt, defaults: defaults)
}

private func testOllamaNormalPageParsesBothMeters() throws {
    let suiteName = "limit-counter-ollama-normal-\(UUID().uuidString)"
    let defaults = try isolatedDefaults(suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let fetchedAt = date("2026-08-18T12:00:00Z")
    let html = """
    <html><body>
    <main>
      <section>
        <h2>Session usage</h2>
        <div role="progressbar" aria-valuenow="12" aria-valuemin="0" aria-valuemax="100"></div>
        <p>Resets in 2 hours</p>
      </section>
      <section>
        <h2>Weekly usage</h2>
        <div role="progressbar" aria-valuenow="34" aria-valuemin="0" aria-valuemax="100"></div>
        <p>Resets in 3 days</p>
      </section>
      <h3>Models used</h3>
    </main>
    </body></html>
    """

    let snapshot = try parseOllama(html, fetchedAt: fetchedAt, defaults: defaults)
    try expectEqual(snapshot.windows.count, 2, "Ollama normal page window count")
    let session = try snapshot.windows.first(where: { $0.windowKind == .session })
        ?? { throw OllamaTestError.failure("Missing Ollama session window") }()
    let weekly = try snapshot.windows.first(where: { $0.windowKind == .weekly })
        ?? { throw OllamaTestError.failure("Missing Ollama weekly window") }()

    try expectClose(session.used, 12, "Ollama session percent")
    try expectClose(weekly.used, 34, "Ollama weekly percent")
    try expectEqual(session.resetDate, fetchedAt.addingTimeInterval(2 * 3_600), "Session reset stays on the session window")
    try expectEqual(weekly.resetDate, fetchedAt.addingTimeInterval(3 * 86_400), "Weekly reset stays on the weekly window")
    try expectEqual(session.subtitle, "Resets in 2h", "Ollama session subtitle")
    try expectEqual(weekly.subtitle, "Resets in 3d", "Ollama weekly subtitle")
}

private func testOllamaWeeklyBannerAttachesResetToWeeklyWindow() throws {
    let suiteName = "limit-counter-ollama-banner-\(UUID().uuidString)"
    let defaults = try isolatedDefaults(suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let fetchedAt = date("2026-08-18T17:38:06Z")
    let html = """
    <html><body>
    <main>
      <section>
        <h2>Session usage</h2>
        <div role="alert">Weekly limit reached &middot; Sessions resume in 5 days.</div>
        <div role="progressbar" aria-valuenow="0" aria-valuemin="0" aria-valuemax="100"></div>
      </section>
      <section>
        <h2>Weekly usage</h2>
        <div class="bar" style="width: 100%"></div>
      </section>
      <h3>Models used</h3>
    </main>
    </body></html>
    """

    let snapshot = try parseOllama(html, fetchedAt: fetchedAt, defaults: defaults)
    try expectEqual(snapshot.windows.count, 2, "Ollama banner page window count")
    let session = try snapshot.windows.first(where: { $0.windowKind == .session })
        ?? { throw OllamaTestError.failure("Missing Ollama session window") }()
    let weekly = try snapshot.windows.first(where: { $0.windowKind == .weekly })
        ?? { throw OllamaTestError.failure("Missing Ollama weekly window") }()

    try expectClose(session.used, 0, "Blocked session bar percent")
    try expectClose(weekly.used, 100, "Exhausted weekly bar percent")
    try expectEqual(weekly.resetDate, fetchedAt.addingTimeInterval(5 * 86_400), "Weekly window carries the resume date")
    try expectEqual(weekly.subtitle, "Weekly limit reached", "Weekly banner subtitle")
    try expect(session.resetDate == nil, "Session window must not take the multi-day resume date")
    try expectEqual(session.subtitle, "Blocked until weekly reset", "Blocked session subtitle")
}

private func testOllamaReorderedLandmarksDoNotTrap() throws {
    let suiteName = "limit-counter-ollama-reordered-\(UUID().uuidString)"
    let defaults = try isolatedDefaults(suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let fetchedAt = date("2026-08-18T12:00:00Z")
    let filler = String(repeating: "lorem ipsum dolor sit amet consectetur ", count: 30)
    let html = """
    <html><body>
    <nav><a href="/settings">Weekly usage overview</a></nav>
    <p>\(filler)</p>
    <main>
      <section>
        <h2>Session usage</h2>
        <div role="progressbar" aria-valuenow="25" aria-valuemin="0" aria-valuemax="100"></div>
      </section>
    </main>
    </body></html>
    """

    let snapshot = try parseOllama(html, fetchedAt: fetchedAt, defaults: defaults)
    try expectEqual(snapshot.windows.count, 1, "Reordered page yields only the parseable meter")
    let session = try snapshot.windows.first(where: { $0.windowKind == .session })
        ?? { throw OllamaTestError.failure("Missing Ollama session window") }()
    try expectClose(session.used, 25, "Reordered page still parses the session meter")
    try expect(
        snapshot.windows.allSatisfy { $0.used >= 0 && $0.used <= 100 },
        "Reordered page yields sane percents"
    )
}

private func testOllamaIgnoresJunkPercentagesInMarkup() throws {
    let suiteName = "limit-counter-ollama-junk-\(UUID().uuidString)"
    let defaults = try isolatedDefaults(suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let fetchedAt = date("2026-08-18T12:00:00Z")
    let padding = String(repeating: "supporting copy without meters ", count: 12)
    let html = """
    <html><body>
    <main>
      <section>
        <h2>Session usage</h2>
        <img src="/chart.png" style="max-width:100%;height:auto">
        <p>\(padding)</p>
        <p>Trusted by 97% of developers surveyed.</p>
      </section>
      <section>
        <h2>Weekly usage</h2>
        <div role="progressbar" aria-label="45% of weekly limit used"></div>
      </section>
      <h3>Models used</h3>
    </main>
    </body></html>
    """

    let snapshot = try parseOllama(html, fetchedAt: fetchedAt, defaults: defaults)
    try expectEqual(snapshot.windows.count, 1, "Junk markup must not fabricate a session meter")
    let weekly = try snapshot.windows.first(where: { $0.windowKind == .weekly })
        ?? { throw OllamaTestError.failure("Missing Ollama weekly window") }()
    try expectClose(weekly.used, 45, "Weekly percent comes from the aria label")
    try expect(
        !snapshot.windows.contains { abs($0.used - 100) < 0.5 },
        "max-width:100% must not become a meter value"
    )
    try expect(
        !snapshot.windows.contains { abs($0.used - 97) < 0.5 },
        "Marketing percentages must not become a meter value"
    )
}

private func testOllamaWeeklyResetStoreKeepsEpisodeDateStable() throws {
    let suiteName = "limit-counter-ollama-reset-store-\(UUID().uuidString)"
    let defaults = try isolatedDefaults(suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let start = date("2026-08-18T17:38:06Z")
    let episodeDate = start.addingTimeInterval(5 * 86_400)

    let adopted = OllamaWeeklyResetStore.stabilizedResetDate(
        candidate: episodeDate,
        now: start,
        defaults: defaults
    )
    try expectEqual(adopted, episodeDate, "First sighting adopts the computed reset")

    let thirtyMinutesLater = start.addingTimeInterval(30 * 60)
    let drifted = OllamaWeeklyResetStore.stabilizedResetDate(
        candidate: thirtyMinutesLater.addingTimeInterval(5 * 86_400),
        now: thirtyMinutesLater,
        defaults: defaults
    )
    try expectEqual(drifted, episodeDate, "Recomputed reset within the episode keeps the stored date")

    let nextDay = start.addingTimeInterval(86_400)
    let coarser = OllamaWeeklyResetStore.stabilizedResetDate(
        candidate: nextDay.addingTimeInterval(5 * 86_400),
        now: nextDay,
        defaults: defaults
    )
    try expectEqual(coarser, episodeDate, "A day-granular recount stays inside the same episode")

    let nextEpisodeNow = start.addingTimeInterval(9 * 86_400)
    let nextEpisodeDate = nextEpisodeNow.addingTimeInterval(6 * 86_400)
    let replaced = OllamaWeeklyResetStore.stabilizedResetDate(
        candidate: nextEpisodeDate,
        now: nextEpisodeNow,
        defaults: defaults
    )
    try expectEqual(replaced, nextEpisodeDate, "A new episode after the stored reset passes adopts the new date")

    let farFuture = nextEpisodeNow.addingTimeInterval(20 * 86_400)
    let jumped = OllamaWeeklyResetStore.stabilizedResetDate(
        candidate: farFuture,
        now: nextEpisodeNow.addingTimeInterval(3_600),
        defaults: defaults
    )
    try expectEqual(jumped, farFuture, "A far-future recomputation replaces the stored date")
}

@main
private enum OllamaUsageTestRunner {
    static func main() throws {
        try testOllamaNormalPageParsesBothMeters()
        try testOllamaWeeklyBannerAttachesResetToWeeklyWindow()
        try testOllamaReorderedLandmarksDoNotTrap()
        try testOllamaIgnoresJunkPercentagesInMarkup()
        try testOllamaWeeklyResetStoreKeepsEpisodeDateStable()
        print("Ollama usage tests passed")
    }
}
