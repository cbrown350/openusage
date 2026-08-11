import XCTest
@testable import OpenUsage

// MARK: - Sample payloads
//
// Captured verbatim from the Qwen Cloud console's "zelda" gateway (Alibaba Cloud). Every response wraps
// the real payload in `data → DataV2 → data → data` with a `code: "SUCCESS"` marker. The usage call
// reports the 5-hour / weekly windows as 0–1 fractions with epoch-ms reset times; the subscription call
// reports the plan tier as `specCode`.

private let usageJSON = #"""
{
  "code": "200",
  "data": {
    "DataV2": {
      "ret": ["SUCCESS::call succeeded"],
      "data": {
        "msg": "Success.",
        "code": "SUCCESS",
        "data": {
          "per5HourPercentage": 0.2685340333272857,
          "per1WeekResetTime": 1785460860000,
          "per5HourResetTime": 1784942280000,
          "per1WeekPercentage": 0.07873230990508
        },
        "requestId": "c409cead-278c-99af-a21a-2bae2d487265",
        "success": true
      }
    },
    "success": true,
    "httpStatus": 200,
    "errorCode": "",
    "api": "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage",
    "errorMsg": ""
  },
  "httpStatusCode": "200",
  "successResponse": true
}
"""#

private let subscriptionJSON = #"""
{
  "code": "200",
  "data": {
    "DataV2": {
      "ret": ["SUCCESS::call succeeded"],
      "data": {
        "msg": "Success.",
        "code": "SUCCESS",
        "data": {
          "instanceCode": "sfm_tokenplansolo_public_intl-sg-jiy4vub2s20",
          "specCode": "lite",
          "remainingDays": 30,
          "startTime": 1784854045000,
          "endTime": 1787587200000,
          "autoRenewFlag": false,
          "status": "VALID"
        },
        "requestId": "6dc97420-f1c6-9a91-9f89-4bf81892afce",
        "success": true
      }
    },
    "success": true,
    "httpStatus": 200
  }
}
"""#

/// A gateway response whose inner envelope reports failure (e.g. a rejected ticket) — no payload.
private let failedEnvelopeJSON = #"""
{ "data": { "DataV2": { "data": { "code": "FAIL", "success": false, "data": null } } } }
"""#

/// A billing page whose embedded config carries the CSRF token the data API requires.
private let billingPageHTML = #"""
<html><head><script>
window.__config = { SEC_TOKEN: "test-sec-token", locale: "en-US" };
</script></head><body></body></html>
"""#

private func json(_ string: String) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: Data(string.utf8))
}

// MARK: - QwenAuthStoreTests

final class QwenAuthStoreTests: XCTestCase {
    func testPrefersConfigFileOverEnvironment() {
        let store = QwenAuthStore(
            files: FakeFiles([QwenAuthStore.configPaths[0]: #"{"apiKey":"ticket-file"}"#]),
            environment: FakeEnvironment(["QWEN_SESSION_COOKIE": "ticket-env"])
        )
        XCTAssertEqual(store.loadSessionTicket()?.sessionTicket, "ticket-file")
    }

    func testFallsBackToEnvironmentWhenNoConfigFile() {
        let store = QwenAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["QWEN_SESSION_COOKIE": "ticket-env"])
        )
        XCTAssertEqual(store.loadSessionTicket()?.sessionTicket, "ticket-env")
    }

    func testExtractsTicketFromFullCookieHeader() {
        // QWEN_COOKIE may hold a whole Cookie header; the login_qwencloud_ticket value is pulled out.
        let store = QwenAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["QWEN_COOKIE": "cna=abc; login_qwencloud_ticket=the-ticket; yunpk=123"])
        )
        XCTAssertEqual(store.loadSessionTicket()?.sessionTicket, "the-ticket")
    }

    func testStripsCookiePrefix() {
        XCTAssertEqual(
            QwenAuthStore.extractTicketValue(from: "Cookie: login_qwencloud_ticket=prefixed"),
            "prefixed"
        )
    }

    func testBareValueWithoutSemicolons() {
        XCTAssertEqual(QwenAuthStore.extractTicketValue(from: "  bare-ticket\n"), "bare-ticket")
    }

    func testHeaderWithoutTicketYieldsNil() {
        XCTAssertNil(QwenAuthStore.extractTicketValue(from: "cna=abc; yunpk=123"))
    }

    func testSaveAndDeleteRoundTrip() throws {
        let files = FakeFiles()
        let store = QwenAuthStore(files: files, environment: FakeEnvironment())
        try store.saveAPIKey("  saved-ticket  ")
        XCTAssertEqual(store.loadSessionTicket()?.sessionTicket, "saved-ticket")
        XCTAssertEqual(store.keyStatus(), .saved)
        try store.deleteAPIKey()
        XCTAssertEqual(store.keyStatus(), .notSet)
    }
}

// MARK: - QwenUsageClientTests

final class QwenUsageClientTests: XCTestCase {
    func testExtractsSecToken() {
        XCTAssertEqual(QwenUsageClient.extractSecToken(from: billingPageHTML), "test-sec-token")
    }

    func testExtractSecTokenNilWhenAbsent() {
        XCTAssertNil(QwenUsageClient.extractSecToken(from: "<html><body>login</body></html>"))
    }
}

// MARK: - QwenUsageMapperTests

final class QwenUsageMapperTests: XCTestCase {
    func testParsesUsageFractionsAndResetTimes() throws {
        let usage = try QwenUsageMapper.parseUsage(Data(usageJSON.utf8))
        // 0.2685… fraction → 26.85…% used; 0.0787… → 7.87…% used.
        XCTAssertEqual(usage.fiveHourPercent, 26.8534, accuracy: 0.001)
        XCTAssertEqual(usage.weeklyPercent, 7.8732, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(usage.fiveHourResetsAt).timeIntervalSince1970, 1_784_942_280, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(usage.weeklyResetsAt).timeIntervalSince1970, 1_785_460_860, accuracy: 1)
    }

    func testMapsPlanAndLines() throws {
        let mapped = try QwenUsageMapper.map(usageBody: Data(usageJSON.utf8), subscriptionBody: Data(subscriptionJSON.utf8))
        XCTAssertEqual(mapped.plan, "Lite")
        let fiveHour = try XCTUnwrap(progress(mapped.lines, "5-Hour Window"))
        XCTAssertEqual(fiveHour.used, 26.8534, accuracy: 0.001)
        XCTAssertEqual(fiveHour.limit, 100)
        XCTAssertEqual(fiveHour.format, .percent)
        XCTAssertEqual(fiveHour.periodDurationMs, 5 * 60 * 60 * 1000)
        let weekly = try XCTUnwrap(progress(mapped.lines, "Weekly"))
        XCTAssertEqual(weekly.periodDurationMs, 7 * 24 * 60 * 60 * 1000)
    }

    func testPlanNameTitleCasesSpecCode() {
        XCTAssertEqual(QwenUsageMapper.planName(from: Data(subscriptionJSON.utf8)), "Lite")
        let pro = Data(#"""
        {"data":{"DataV2":{"data":{"code":"SUCCESS","success":true,"data":{"specCode":"pro"}}}}}
        """#.utf8)
        XCTAssertEqual(QwenUsageMapper.planName(from: pro), "Pro")
    }

    func testPlanNameNilWhenSubscriptionMissing() {
        XCTAssertNil(QwenUsageMapper.planName(from: Data(failedEnvelopeJSON.utf8)))
    }

    func testClampsAboveRangeFraction() throws {
        let over = Data(#"""
        {"data":{"DataV2":{"data":{"code":"SUCCESS","success":true,
          "data":{"per5HourPercentage":1.5,"per1WeekPercentage":-0.2}}}}}
        """#.utf8)
        let usage = try QwenUsageMapper.parseUsage(over)
        XCTAssertEqual(usage.fiveHourPercent, 100)
        XCTAssertEqual(usage.weeklyPercent, 0)
    }

    func testParseUsageThrowsOnFailedEnvelope() {
        XCTAssertThrowsError(try QwenUsageMapper.parseUsage(Data(failedEnvelopeJSON.utf8))) { error in
            XCTAssertEqual(error as? QwenUsageError, .invalidResponse)
        }
    }

    func testParseUsageThrowsWhenFieldsMissing() {
        let missing = Data(#"""
        {"data":{"DataV2":{"data":{"code":"SUCCESS","success":true,"data":{"unrelated":1}}}}}
        """#.utf8)
        XCTAssertThrowsError(try QwenUsageMapper.parseUsage(missing))
    }

    func testDataPayloadNilOnNonSuccess() {
        XCTAssertNil(QwenUsageMapper.dataPayload(Data(failedEnvelopeJSON.utf8)))
        XCTAssertNil(QwenUsageMapper.dataPayload(Data("garbage".utf8)))
    }

    // MARK: Flattened envelope (console SPA migration)

    /// Regression: the console dropped the `DataV2` wrapper, so the gateway now answers
    /// `data → data` directly. The old unwrapper required `DataV2` and returned nil for every
    /// response, surfacing as "Could not parse Qwen Token Plan usage" on a perfectly valid ticket.
    func testParseUsageAcceptsFlattenedEnvelope() throws {
        let flattened = Data(#"""
        {"code":"200","data":{"code":"SUCCESS","success":true,
          "data":{"per5HourPercentage":0.25,"per1WeekPercentage":0.5,
                  "per5HourResetTime":1784942280000,"per1WeekResetTime":1785460860000}}}
        """#.utf8)
        let usage = try QwenUsageMapper.parseUsage(flattened)
        XCTAssertEqual(usage.fiveHourPercent, 25, accuracy: 0.001)
        XCTAssertEqual(usage.weeklyPercent, 50, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(usage.fiveHourResetsAt).timeIntervalSince1970, 1_784_942_280, accuracy: 1)
    }

    func testPlanNameFromFlattenedEnvelope() {
        let flattened = Data(#"""
        {"data":{"code":"SUCCESS","success":true,"data":{"specCode":"pro"}}}
        """#.utf8)
        XCTAssertEqual(QwenUsageMapper.planName(from: flattened), "Pro")
    }

    /// The gateway reports a dead ticket as HTTP 200 with `errorCode: BailianGateway.Login.NotLogined`,
    /// so it must be classified as an expired session rather than a parse failure. Captured verbatim.
    func testDetectsNotLoggedInEnvelope() {
        let notLogined = Data(#"""
        {"code":"200","data":{"success":false,"httpStatus":200,
          "errorCode":"BailianGateway.Login.NotLogined",
          "api":"zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage",
          "errorMsg":"BailianGateway.Login.NotLogined"},
          "httpStatusCode":"200","successResponse":true}
        """#.utf8)
        XCTAssertTrue(QwenUsageMapper.isNotLoggedIn(notLogined))
        XCTAssertNil(QwenUsageMapper.dataPayload(notLogined))
    }

    func testNotLoggedInFalseForValidPayloads() {
        XCTAssertFalse(QwenUsageMapper.isNotLoggedIn(Data(usageJSON.utf8)))
        XCTAssertFalse(QwenUsageMapper.isNotLoggedIn(Data("garbage".utf8)))
    }

    /// Regression: Qwen omits the 5-hour window fields (`per5HourPercentage`, `per5HourResetTime`)
    /// when no session window is active. Previously that was treated as an invalid response; now the
    /// 5-hour meter reads 0% while the weekly meter still shows real usage. Captured from a live ticket.
    func testParseUsageHandlesMissingFiveHourWindow() throws {
        let missing5h = Data(#"""
        {"code":"200","data":{"DataV2":{"ret":["SUCCESS"],"data":{"msg":"Success.","code":"SUCCESS","success":true,"data":{"per1WeekResetTime":1787008560000,"per1WeekPercentage":0.284497583929}}},"success":true,"httpStatus":200,"errorCode":"","api":"zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage","errorMsg":""},"httpStatusCode":"200","successResponse":true}
        """#.utf8)
        let usage = try QwenUsageMapper.parseUsage(missing5h)
        XCTAssertEqual(usage.fiveHourPercent, 0)
        XCTAssertEqual(usage.weeklyPercent, 28.4498, accuracy: 0.001)
        XCTAssertNil(usage.fiveHourResetsAt)
        XCTAssertNotNil(usage.weeklyResetsAt)
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, format: ProgressFormat, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, let format, _, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, format, periodDurationMs)
    }
}

// MARK: - QwenProviderTests

@MainActor
final class QwenProviderTests: XCTestCase {
    /// Routes the three-call flow: GET billing page → POST usage → POST subscription.
    private func routingClient(
        page: @escaping @Sendable () -> HTTPResponse = { json(billingPageHTML) },
        usage: @escaping @Sendable () -> HTTPResponse = { json(usageJSON) },
        subscription: @escaping @Sendable () -> HTTPResponse = { json(subscriptionJSON) },
        assertCookie: Bool = true,
        expectedSecToken: String? = "test-sec-token"
    ) -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            if request.url == QwenUsageClient.billingPageURL {
                if assertCookie {
                    XCTAssertEqual(request.headers["Cookie"], "login_qwencloud_ticket=ticket-value")
                }
                return page()
            }
            let urlString = request.url.absoluteString
            if urlString.contains("v2%2Fusage") {
                // The CSRF token lifted from the page rides in the form body. It is empty when the page
                // carries no token — the gateway authorizes on the ticket cookie, not on `sec_token`.
                if let expectedSecToken {
                    let body = String(decoding: request.body ?? Data(), as: UTF8.self)
                    XCTAssertTrue(body.contains("sec_token=\(expectedSecToken)"))
                }
                return usage()
            }
            if urlString.contains("v2%2Fsubscription") {
                return subscription()
            }
            XCTFail("unexpected request: \(urlString)")
            return json("{}")
        }
    }

    func testRefreshRunsTwoStepFlowAndMaps() async throws {
        let provider = QwenProvider(
            authStore: makeAuthStore(ticket: "ticket-value"),
            usageClient: QwenUsageClient(http: routingClient()),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Lite")
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "5-Hour Window"))
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
    }

    func testRefreshSurvivesSubscriptionFailure() async {
        // The subscription endpoint is best-effort (plan name only); a failure must not blank the meters.
        let provider = QwenProvider(
            authStore: makeAuthStore(ticket: "ticket-value"),
            usageClient: QwenUsageClient(http: routingClient(
                subscription: { HTTPResponse(statusCode: 500, headers: [:], body: Data("{}".utf8)) }
            ))
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.plan)
        XCTAssertNotNil(snapshot.line(label: "5-Hour Window"))
    }

    func testRefreshWithoutTicketReportsNotLoggedIn() async {
        let provider = QwenProvider(
            authStore: QwenAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: QwenUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("should not hit the network without a ticket")
                return json(usageJSON)
            })
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.lines.first?.label, "Error")
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    /// Regression: the console SPA no longer embeds `SEC_TOKEN`, so a token-less page is the normal
    /// case — not an expired session. Previously this bailed early with `.authExpired`, which made every
    /// refresh fail with "session expired" even right after the user pasted a fresh ticket.
    func testRefreshSucceedsWhenPageHasNoSecToken() async {
        let provider = QwenProvider(
            authStore: makeAuthStore(ticket: "ticket-value"),
            usageClient: QwenUsageClient(http: routingClient(
                page: { json("<html><body>SPA shell, no token</body></html>") },
                expectedSecToken: ""
            ))
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "5-Hour Window"))
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
    }

    /// An actually-expired ticket is signalled by the gateway in the envelope (HTTP 200 +
    /// `BailianGateway.Login.NotLogined`), not by the absence of a token on the page.
    func testRefreshReportsExpiredSessionOnNotLoginedEnvelope() async {
        let notLogined = #"""
        {"code":"200","data":{"success":false,"httpStatus":200,
          "errorCode":"BailianGateway.Login.NotLogined","errorMsg":"BailianGateway.Login.NotLogined"}}
        """#
        let provider = QwenProvider(
            authStore: makeAuthStore(ticket: "stale"),
            usageClient: QwenUsageClient(http: routingClient(
                page: { json("<html><body>SPA shell</body></html>") },
                usage: { json(notLogined) },
                assertCookie: false,
                expectedSecToken: nil
            ))
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
    }

    func testRefreshOnPageRedirectReportsExpiredSession() async {
        let provider = QwenProvider(
            authStore: makeAuthStore(ticket: "stale"),
            usageClient: QwenUsageClient(http: RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 302, headers: [:], body: Data())
            })
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
    }

    func testRefreshOnUsageNon2xxReportsRequestFailed() async {
        let provider = QwenProvider(
            authStore: makeAuthStore(ticket: "ticket-value"),
            usageClient: QwenUsageClient(http: routingClient(
                usage: { HTTPResponse(statusCode: 500, headers: [:], body: Data("{}".utf8)) }
            ))
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .http5xx)
    }

    func testRefreshOnFailedUsageEnvelopeReportsDecoding() async {
        let provider = QwenProvider(
            authStore: makeAuthStore(ticket: "ticket-value"),
            usageClient: QwenUsageClient(http: routingClient(usage: { json(failedEnvelopeJSON) }))
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .decoding)
    }

    func testRefreshOnTransportErrorReportsNetwork() async {
        let provider = QwenProvider(
            authStore: makeAuthStore(ticket: "ticket-value"),
            usageClient: QwenUsageClient(http: RoutingHTTPClient { _ in throw QwenUsageError.connectionFailed })
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .network)
    }

    func testHasLocalCredentialsReflectsTicket() async {
        let withTicket = QwenProvider(authStore: makeAuthStore(ticket: "t"),
                                      usageClient: QwenUsageClient(http: routingClient()))
        let without = QwenProvider(authStore: QwenAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
                                   usageClient: QwenUsageClient(http: routingClient()))
        let withTicketCreds = await withTicket.hasLocalCredentials()
        let withoutCreds = await without.hasLocalCredentials()
        XCTAssertTrue(withTicketCreds)
        XCTAssertFalse(withoutCreds)
    }

    func testAPIKeyManagingDelegatesAndUsesSessionKind() throws {
        let files = FakeFiles()
        let provider = QwenProvider(
            authStore: QwenAuthStore(files: files, environment: FakeEnvironment(["QWEN_SESSION_COOKIE": "env-ticket"])),
            usageClient: QwenUsageClient(http: routingClient(assertCookie: false))
        )

        if case .sessionKey(let cookieName) = provider.credentialKind {
            XCTAssertEqual(cookieName, "login_qwencloud_ticket")
        } else {
            XCTFail("Qwen should manage a session key, not an API key")
        }

        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
        XCTAssertEqual(provider.currentAPIKey(), "env-ticket")
        try provider.saveAPIKey("saved-ticket")
        XCTAssertEqual(provider.apiKeyStatus, .overrideActive)
        try provider.deleteAPIKey()
        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
    }

    func testProviderIdentityAndLinks() {
        let provider = QwenProvider()
        XCTAssertEqual(provider.provider.id, "qwen")
        XCTAssertEqual(provider.provider.displayName, "Qwen")
        XCTAssertEqual(provider.provider.visibleLinks.count, 1)
    }

    private func makeAuthStore(ticket: String) -> QwenAuthStore {
        QwenAuthStore(files: FakeFiles(), environment: FakeEnvironment(["QWEN_SESSION_COOKIE": ticket]))
    }
}
