import XCTest
@testable import CodexUsageKit

final class CodexAuthFileImporterTests: XCTestCase {
    func testImportsNestedCodexAuthJSON() throws {
        let data = Data("""
        {
          "OPENAI_API_KEY": "must-not-be-imported",
          "tokens": {
            "access_token": " access-token ",
            "account_id": " account-id ",
            "refresh_token": "must-not-be-imported",
            "id_token": "must-not-be-imported"
          }
        }
        """.utf8)

        let credential = try CodexAuthFileImporter.importCredential(from: data)

        XCTAssertEqual(credential.accessToken, "access-token")
        XCTAssertEqual(credential.accountID, "account-id")
    }

    func testImportsDirectCodexAuthJSON() throws {
        let data = Data("""
        {
          "access_token": "direct-token",
          "account_id": "direct-account"
        }
        """.utf8)

        let credential = try CodexAuthFileImporter.importCredential(from: data)

        XCTAssertEqual(credential.accessToken, "direct-token")
        XCTAssertEqual(credential.accountID, "direct-account")
    }

    func testMissingAccessTokenThrows() {
        let data = Data("""
        { "tokens": { "account_id": "account-id" } }
        """.utf8)

        XCTAssertThrowsError(try CodexAuthFileImporter.importCredential(from: data)) { error in
            XCTAssertEqual(error as? CodexUsageError, .missingAccessToken)
        }
    }

    func testMissingAccountIDThrows() {
        let data = Data("""
        { "tokens": { "access_token": "access-token" } }
        """.utf8)

        XCTAssertThrowsError(try CodexAuthFileImporter.importCredential(from: data)) { error in
            XCTAssertEqual(error as? CodexUsageError, .missingAccountID)
        }
    }

    func testMalformedJSONThrows() {
        let data = Data("{".utf8)

        XCTAssertThrowsError(try CodexAuthFileImporter.importCredential(from: data)) { error in
            XCTAssertEqual(error as? CodexUsageError, .invalidAuthFile)
        }
    }
}
