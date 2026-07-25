import Foundation

struct OllamaUsageClient: Sendable {
    static let settingsURL = URL(string: "https://ollama.com/settings")!
    static let apiUsageURL = URL(string: "https://ollama.com/api/account/usage")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Fetch the authenticated settings page HTML using the `__Secure-session` cookie. This is the
    /// primary data source — Ollama does not yet document a cloud quota API.
    func fetchSettingsPage(sessionCookie: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.settingsURL,
            headers: [
                "Accept": "text/html",
                "Cookie": "__Secure-session=\(sessionCookie)",
                "User-Agent": "OpenUsage"
            ],
            timeout: 15
        ))
    }

    /// Fallback: query a future `/api/account/usage` endpoint with an API key. Today this endpoint
    /// is expected to be absent (404); the provider treats that gracefully.
    func fetchAPIUsage(apiKey: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.apiUsageURL,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }
}

enum OllamaUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case sessionExpired
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Could not reach ollama.com. Check your connection."
        case .sessionExpired:
            return "Ollama session expired. Update your session cookie."
        case .invalidResponse:
            return "Could not parse Ollama Cloud usage from settings."
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        }
    }
}
