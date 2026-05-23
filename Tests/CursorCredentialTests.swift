import Foundation
import SQLite3

enum CursorTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

func cursorExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw CursorTestFailure.failed(message)
    }
}

func cursorExpectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw CursorTestFailure.failed("\(message): expected \(expected), got \(actual)")
    }
}

@main
enum CursorCredentialTestRunner {
    static func main() async throws {
        try testImportsCursorStateDirectory()
        try testImportsCursorStateFile()
        try await testCursorProviderReadsDirectoryState()
        print("Cursor credential tests passed")
    }

    private static func testImportsCursorStateDirectory() throws {
        let directory = try temporaryDirectory()
        let stateDB = directory.appendingPathComponent("state.vscdb")
        FileManager.default.createFile(atPath: stateDB.path, contents: Data())

        let imported = try CredentialImportService.importFromURL(directory, for: .cursor)

        try cursorExpectEqual(imported.customEndpoint, stateDB.path, "directory import endpoint")
        try cursorExpectEqual(imported.extraFields?["cursorAuthMode"], "localState", "directory auth mode")
        try cursorExpectEqual(imported.extraFields?["cursorLocalStateSource"], "directory", "directory source")
    }

    private static func testImportsCursorStateFile() throws {
        let directory = try temporaryDirectory()
        let stateDB = directory.appendingPathComponent("state.vscdb")
        FileManager.default.createFile(atPath: stateDB.path, contents: Data())

        let imported = try CredentialImportService.importFromURL(stateDB, for: .cursor)

        try cursorExpectEqual(imported.customEndpoint, stateDB.path, "file import endpoint")
        try cursorExpectEqual(imported.extraFields?["cursorAuthMode"], "localState", "file auth mode")
        try cursorExpectEqual(imported.extraFields?["cursorLocalStateSource"], "file", "file source")
    }

    private static func testCursorProviderReadsDirectoryState() async throws {
        let directory = try temporaryDirectory()
        let stateDB = directory.appendingPathComponent("state.vscdb")
        try createCursorStateDatabase(at: stateDB)

        let credential = ProviderCredential(
            customEndpoint: directory.path,
            extraFields: [
                "cursorAuthMode": "localState"
            ]
        )

        let snapshot = try await CursorProviderClient().fetchSnapshot(credentials: credential)

        try cursorExpectEqual(snapshot.providerID, .cursor, "provider")
        try cursorExpectEqual(snapshot.planName, "Pro", "local membership plan")
        try cursorExpect(snapshot.stats.contains { $0.label == "Tracked AI Days" && $0.value == 1 }, "tracked day stat")
        try cursorExpectEqual(snapshot.events.count, 1, "local daily activity events")
    }

    private static func createCursorStateDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw CursorTestFailure.failed("could not create sqlite database")
        }
        defer { sqlite3_close(db) }

        try exec("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);", db: db)
        try insert(key: "cursorAuth/cachedEmail", value: "cursor@example.com", db: db)
        try insert(key: "cursorAuth/cachedMembershipType", value: "pro", db: db)
        try insert(
            key: "aiCodeTracking.dailyStats.2026-05-12",
            value: """
            {"date":"2026-05-12","tabSuggestedLines":7,"tabAcceptedLines":3,"composerSuggestedLines":11,"composerAcceptedLines":5}
            """,
            db: db
        )
    }

    private static func insert(key: String, value: String, db: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO ItemTable (key, value) VALUES (?, ?);", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CursorTestFailure.failed("could not prepare insert")
        }
        defer { sqlite3_finalize(statement) }

        let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transientDestructor)
        sqlite3_bind_text(statement, 2, value, -1, transientDestructor)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CursorTestFailure.failed("could not insert \(key)")
        }
    }

    private static func exec(_ sql: String, db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            if let errorMessage {
                sqlite3_free(errorMessage)
            }
        }

        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            throw CursorTestFailure.failed(message)
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
