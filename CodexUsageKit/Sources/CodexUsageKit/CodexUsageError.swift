import Foundation

public enum CodexUsageError: Error, Equatable, LocalizedError, Sendable {
    case invalidAuthFile
    case missingAccessToken
    case missingAccountID
    case invalidCredential
    case rateLimited
    case invalidResponse
    case unexpectedStatusCode(Int)
    case decodingFailed
    case telemetryUnavailable
    case fileReadFailed
    case networkFailed

    public var errorDescription: String? {
        switch self {
        case .invalidAuthFile:
            return "The selected Codex auth file is not valid JSON."
        case .missingAccessToken:
            return "The Codex auth file does not contain an access token."
        case .missingAccountID:
            return "The Codex auth file does not contain a ChatGPT account ID."
        case .invalidCredential:
            return "The Codex credential was rejected."
        case .rateLimited:
            return "Codex usage data is currently rate limited."
        case .invalidResponse:
            return "Codex usage returned an invalid response."
        case .unexpectedStatusCode(let statusCode):
            return "Codex usage returned HTTP \(statusCode)."
        case .decodingFailed:
            return "Codex usage data could not be decoded."
        case .telemetryUnavailable:
            return "No Codex telemetry data was found."
        case .fileReadFailed:
            return "The selected Codex file could not be read."
        case .networkFailed:
            return "Codex usage could not be reached."
        }
    }
}
