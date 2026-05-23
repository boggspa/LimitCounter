import Foundation
import XCTest
@testable import CodexUsageKit

final class CodexTelemetryReaderTests: XCTestCase {
    func testReadsLocalJSONLTelemetryIntoSnapshot() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = """
        {"timestamp":"\(timestamp)","event":"response.completed","conversation_id":"thread-1","response":{"usage":{"input_tokens":10,"output_tokens":5}}}
        """
        try line.write(to: root.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        let snapshot = try await CodexTelemetryReader().readSnapshot(rootURL: root)

        XCTAssertEqual(snapshot.providerID, .codexTelemetry)
        XCTAssertEqual(snapshot.displayName, "Codex Telemetry")
        XCTAssertEqual(snapshot.planName, "Local Logs")
        XCTAssertEqual(snapshot.fetchState, .success)
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events.first?.tokens, 15)
        XCTAssertEqual(stat("24H Tokens", in: snapshot)?.value, 15)
        XCTAssertEqual(stat("7D Tokens", in: snapshot)?.value, 15)
        XCTAssertEqual(stat("24H Responses", in: snapshot)?.value, 1)
        XCTAssertEqual(stat("Active Threads", in: snapshot)?.value, 1)
    }

    func testEmptyTelemetryThrowsUnavailable() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await CodexTelemetryReader().readSnapshot(rootURL: root)
            XCTFail("Expected telemetryUnavailable")
        } catch {
            XCTAssertEqual(error as? CodexUsageError, .telemetryUnavailable)
        }
    }

    private func stat(_ label: String, in snapshot: QuotaSnapshot) -> QuotaStat? {
        snapshot.stats.first { $0.label == label }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageKitTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
