import Foundation

public struct CodexUsageCredential: Codable, Equatable, Hashable, Sendable {
    public let accessToken: String
    public let accountID: String

    public init(accessToken: String, accountID: String) throws {
        let normalizedAccessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAccountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedAccessToken.isEmpty else {
            throw CodexUsageError.missingAccessToken
        }
        guard !normalizedAccountID.isEmpty else {
            throw CodexUsageError.missingAccountID
        }

        self.accessToken = normalizedAccessToken
        self.accountID = normalizedAccountID
    }
}
