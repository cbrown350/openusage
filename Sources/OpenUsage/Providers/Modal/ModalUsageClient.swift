import Foundation

struct ModalUsageClient: Sendable {
    /// The workspace list: the only Modal dashboard endpoint that carries the billing object
    /// (`cycleUsage`, `grantedCycleCredits`, `cycleSpendLimit`, `planType`) plus the workspace
    /// `username` used to route the per-workspace endpoints. Authenticated purely by the
    /// `modal-session` cookie — the dashboard's REST API is a plain JSON service, not the gRPC the
    /// CLI/SDK uses.
    static let workspacesURL = URL(string: "https://modal.com/api/user/workspaces")!
    /// The Dashboard page the provider links to.
    static let usagePageURL = URL(string: "https://modal.com/settings/usage")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// `GET /api/user/workspaces` — the billing object for every Modal workspace the session can see.
    func fetchWorkspaces(sessionCookie: String) async throws -> HTTPResponse {
        try await get(Self.workspacesURL, sessionCookie: sessionCookie)
    }

    /// `GET /api/workspaces/{workspace}/billing-cycles` — `{cycles:[{start,end,isCurrent}]}` for the
    /// reset date that the workspace object itself doesn't carry; routed by workspace `username`.
    func fetchBillingCycles(workspace: String, sessionCookie: String) async throws -> HTTPResponse {
        let encoded = workspace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workspace
        let url = URL(string: "https://modal.com/api/workspaces/\(encoded)/billing-cycles")!
        return try await get(url, sessionCookie: sessionCookie)
    }

    private func get(_ url: URL, sessionCookie: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Accept": "application/json",
                "Cookie": "\(ModalAuthStore.sessionCookieName)=\(sessionCookie)",
                "User-Agent": "OpenUsage"
            ],
            timeout: 15
        ))
    }
}

enum ModalUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case sessionExpired
    case noWorkspace
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .sessionExpired:
            return "Modal session expired. Update your session cookie."
        case .noWorkspace:
            return "No Modal workspace on this account."
        case .invalidResponse:
            return "Could not parse Modal usage."
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        }
    }
}
