import Foundation

struct QwenUsageClient: Sendable {
    /// The billing console page. Fetched first to lift the CSRF `SEC_TOKEN` the data API requires; the
    /// token is embedded in the server-rendered HTML as `SEC_TOKEN: "…"`.
    static let billingPageURL = URL(string: "https://home.qwencloud.com/billing/subscription/token-plan-individual")!
    /// Alibaba Cloud's "zelda" gateway the console SPA posts to. The individual API is selected by the
    /// `api` query parameter and the `params` form field (see `paramsJSON`).
    static let gatewayURL = URL(string: "https://cs-data.qwencloud.com/data/api.json")!

    static let usageAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
    static let subscriptionAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription"
    /// Required in the subscription call's `params.Data` to select the international solo token plan.
    static let subscriptionCommodityCode = "sfm_tokenplansolo_public_intl"

    private static let product = "sfm_bailian"
    private static let action = "IntlBroadScopeAspnGateway"
    private static let region = "ap-southeast-1"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Step 1: the authenticated billing page, whose HTML carries the `SEC_TOKEN` the data API needs.
    func fetchBillingPage(sessionTicket: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.billingPageURL,
            headers: [
                "Accept": "text/html",
                "Cookie": "\(QwenAuthStore.ticketCookieName)=\(sessionTicket)",
                "User-Agent": Self.userAgent
            ],
            timeout: 15
        ))
    }

    /// Step 2a: the token-plan usage window percentages and reset times.
    func fetchUsage(sessionTicket: String, secToken: String) async throws -> HTTPResponse {
        try await post(api: Self.usageAPI, sessionTicket: sessionTicket, secToken: secToken, extraData: "")
    }

    /// Step 2b: the active subscription (plan tier, status, remaining days) — best-effort, plan name only.
    func fetchSubscription(sessionTicket: String, secToken: String) async throws -> HTTPResponse {
        try await post(
            api: Self.subscriptionAPI, sessionTicket: sessionTicket, secToken: secToken,
            extraData: "\"commodityCode\":\"\(Self.subscriptionCommodityCode)\","
        )
    }

    /// Lift the CSRF token from the billing page HTML: `SEC_TOKEN: "…"`.
    static func extractSecToken(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"SEC_TOKEN:\s*"([^"]+)""#) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let tokenRange = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[tokenRange]).nilIfEmpty
    }

    // MARK: - Private

    private func post(api: String, sessionTicket: String, secToken: String, extraData: String) async throws -> HTTPResponse {
        let url = URL(string:
            "\(Self.gatewayURL.absoluteString)?product=\(Self.product)&action=\(Self.action)&api=\(api.urlFormEncoded)"
        )!
        let body =
            "product=\(Self.product)" +
            "&action=\(Self.action)" +
            "&sec_token=\(secToken.urlFormEncoded)" +
            "&region=\(Self.region)" +
            "&params=\(Self.paramsJSON(api: api, extraData: extraData).urlFormEncoded)"

        return try await http.send(HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded",
                "Cookie": "\(QwenAuthStore.ticketCookieName)=\(sessionTicket)",
                "Origin": "https://home.qwencloud.com",
                "Referer": Self.billingPageURL.absoluteString,
                "User-Agent": Self.userAgent
            ],
            body: Data(body.utf8),
            timeout: 15
        ))
    }

    /// The gateway `params` field: the individual API name plus the fixed `cornerstoneParam` console
    /// context the gateway routes on. `extraData` injects call-specific fields (the subscription's
    /// `commodityCode`) ahead of `cornerstoneParam`. Built as a literal so the wire format matches the
    /// console SPA exactly rather than depending on dictionary key ordering.
    private static func paramsJSON(api: String, extraData: String) -> String {
        "{\"Api\":\"\(api)\"," +
        "\"Data\":{\(extraData)" +
        "\"cornerstoneParam\":{" +
        "\"domain\":\"home.qwencloud.com\"," +
        "\"consoleSite\":\"QWENCLOUD\"," +
        "\"console\":\"ONE_CONSOLE\"," +
        "\"xsp_lang\":\"en-US\"," +
        "\"protocol\":\"V2\"," +
        "\"productCode\":\"p_efm\"}}," +
        "\"V\":\"1.0\"}"
    }

    /// A browser-like UA — the console gateway rejects the default `OpenUsage` agent on some calls.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
}

enum QwenUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case sessionExpired
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .sessionExpired:
            return "Qwen session expired. Update your session ticket."
        case .invalidResponse:
            return "Could not parse Qwen Token Plan usage."
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        }
    }
}
