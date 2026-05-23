import Foundation

public enum CodexAuthFileImporter {
    public static func importCredential(from url: URL) throws -> CodexUsageCredential {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CodexUsageError.fileReadFailed
        }
        return try importCredential(from: data)
    }

    public static func importCredential(from data: Data) throws -> CodexUsageCredential {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CodexUsageError.invalidAuthFile
        }

        guard let json = object as? [String: Any] else {
            throw CodexUsageError.invalidAuthFile
        }

        let accessToken: String?
        let accountID: String?

        if let tokens = json["tokens"] as? [String: Any] {
            accessToken = tokens["access_token"] as? String
            accountID = tokens["account_id"] as? String
        } else {
            accessToken = json["access_token"] as? String
            accountID = json["account_id"] as? String
        }

        guard let accessToken else {
            throw CodexUsageError.missingAccessToken
        }
        guard let accountID else {
            throw CodexUsageError.missingAccountID
        }

        return try CodexUsageCredential(accessToken: accessToken, accountID: accountID)
    }
}
