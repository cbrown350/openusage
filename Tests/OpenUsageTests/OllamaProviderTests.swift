import XCTest
@testable import OpenUsage

// MARK: - Sample payloads
//
// HTML fixtures ported verbatim from the legacy Tauri plugin's `plugin.test.js` (PR #470): a logged-in
// `ollama.com/settings` page carries a "Cloud Usage <Plan>" heading, two `N% used` meters (Session then
// Weekly), and ISO-8601 `data-time` reset timestamps — or, on older pages, relative "Resets in …" text.

private let settingsHTML = #"""
<main>
  <h1>Cloud Usage <span>Pro</span></h1>
  <section>
    <h2>Session usage</h2>
    <span class="text-sm">0.6% used</span>
    <time data-time="2026-05-16T14:55:00Z">Resets in 55 minutes</time>
  </section>
  <section>
    <h2>Weekly usage</h2>
    <span class="text-sm">17.9% used</span>
    <time data-time="2026-05-17T13:00:00Z">Resets in 1 day</time>
  </section>
</main>
"""#

private let relativeHTML = #"""
<main>
  <h1>Cloud Usage <span>Max</span></h1>
  <section>
    <h2>Session usage</h2>
    <span>2.5% used</span>
    <p>Resets in 30 minutes</p>
  </section>
  <section>
    <h2>Weekly usage</h2>
    <span>10% used</span>
    <p>Resets in 2 days</p>
  </section>
</main>
"""#

/// A logged-out settings page (redirected to login): no "Cloud Usage" marker.
private let loginHTML = #"""
<html><body><h1>Sign in to Ollama</h1></body></html>
"""#

/// The current (2026-07) production settings page, captured live: the heading is lowercase "Cloud usage"
/// with a lowercase "pro" plan badge, and each meter's percentage lives in its `aria-label`. The Session
/// meter is capped here, so its visible text reads "Weekly limit reached" instead of "N% used" — the 0%
/// value survives only in `aria-label="Session usage 0% used"`. This shape broke the old parser, which
/// required a case-sensitive "Cloud Usage" and scraped two visible "N% used" strings.
private let modernSettingsHTML = #"""
<main>
  <h2 class="text-xl font-medium flex items-center space-x-2">
    <span>Cloud usage</span>
    <span class="text-xs font-normal px-2 py-0.5 rounded-full bg-neutral-100 text-neutral-600 capitalize">pro</span>
  </h2>
  <p class="text-xs text-neutral-500 mb-4">
    Cloud models and capabilities such as web search contribute to session and weekly limits.
  </p>
  <div>
    <div class="flex justify-between mb-2">
      <span class="text-sm text-neutral-400">Session usage</span>
      <span class="text-sm text-neutral-500"> Weekly limit reached </span>
    </div>
    <div class="relative group" data-usage-meter>
      <div class="rounded-full bg-neutral-200" data-usage-track aria-label="Session usage 0% used">
        <div class="flex h-full overflow-hidden bg-neutral-950" style="width: 100%; background: #d4d4d4;"></div>
      </div>
    </div>
    <div class="text-xs text-neutral-500 mt-1 local-time" data-time="2026-07-27T00:00:00Z"> Sessions resume in 1 day. </div>
  </div>
  <div>
    <div class="flex justify-between mb-2">
      <span class="text-sm">Weekly usage</span>
      <span class="text-sm text-red-500">100% used</span>
    </div>
    <div class="relative group" data-usage-meter>
      <div class="rounded-full bg-neutral-200" data-usage-track aria-label="Weekly usage 100% used">
        <div class="flex h-full overflow-hidden bg-neutral-950" style="width: 100%"></div>
      </div>
    </div>
    <div class="text-xs text-neutral-500 mt-1 local-time" data-time="2026-07-27T00:00:00Z"> Resets in 1 day. </div>
  </div>
</main>
"""#

private func html(_ string: String) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: Data(string.utf8))
}

// MARK: - OllamaAuthStoreTests

final class OllamaAuthStoreTests: XCTestCase {
    func testPrefersConfigFileOverEnvironment() {
        let store = OllamaAuthStore(
            files: FakeFiles([OllamaAuthStore.configPaths[0]: #"{"apiKey":"cookie-file"}"#]),
            environment: FakeEnvironment(["OLLAMA_SESSION_COOKIE": "cookie-env"])
        )
        XCTAssertEqual(store.loadSessionCookie()?.sessionCookie, "cookie-file")
    }

    func testFallsBackToEnvironmentWhenNoConfigFile() {
        let store = OllamaAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["OLLAMA_SESSION_COOKIE": "cookie-env"])
        )
        XCTAssertEqual(store.loadSessionCookie()?.sessionCookie, "cookie-env")
    }

    func testExtractsSessionValueFromFullCookieHeader() {
        // OLLAMA_COOKIE may hold a whole Cookie header; the __Secure-session value is pulled out.
        let store = OllamaAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["OLLAMA_COOKIE": "other=abc; __Secure-session=the-session; more=1"])
        )
        XCTAssertEqual(store.loadSessionCookie()?.sessionCookie, "the-session")
    }

    func testStripsCookiePrefix() {
        let value = OllamaAuthStore.extractSessionValue(from: "Cookie: __Secure-session=prefixed-value")
        XCTAssertEqual(value, "prefixed-value")
    }

    func testBareValueWithoutSemicolons() {
        XCTAssertEqual(OllamaAuthStore.extractSessionValue(from: "  bare-value\n"), "bare-value")
    }

    func testHeaderWithoutSessionCookieYieldsNil() {
        XCTAssertNil(OllamaAuthStore.extractSessionValue(from: "other=abc; more=1"))
    }

    func testLoadAPIKeyReadsEnvOnly() {
        let store = OllamaAuthStore(files: FakeFiles(), environment: FakeEnvironment(["OLLAMA_API_KEY": "  key-123 "]))
        XCTAssertEqual(store.loadAPIKey(), "key-123")
    }

    func testLoadAPIKeyNilWhenAbsent() {
        let store = OllamaAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertNil(store.loadAPIKey())
    }

    func testSaveAndDeleteRoundTrip() throws {
        let files = FakeFiles()
        let store = OllamaAuthStore(files: files, environment: FakeEnvironment())
        try store.saveAPIKey("  saved-cookie  ")
        XCTAssertEqual(store.loadSessionCookie()?.sessionCookie, "saved-cookie")
        XCTAssertEqual(store.keyStatus(), .saved)
        try store.deleteAPIKey()
        XCTAssertEqual(store.keyStatus(), .notSet)
    }
}

// MARK: - OllamaUsageMapperTests

final class OllamaUsageMapperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testParsesDataTimeSettingsPage() throws {
        let usage = try XCTUnwrap(OllamaUsageMapper.parseSettings(html: settingsHTML, now: now))
        XCTAssertEqual(usage.plan, "Pro")
        XCTAssertEqual(usage.sessionPercent, 0.6, accuracy: 0.001)
        XCTAssertEqual(usage.weeklyPercent, 17.9, accuracy: 0.001)
        // data-time="2026-05-16T14:55:00Z" / "2026-05-17T13:00:00Z"
        XCTAssertEqual(try XCTUnwrap(usage.sessionResetsAt).timeIntervalSince1970,
                       ISO8601DateFormatter().date(from: "2026-05-16T14:55:00Z")!.timeIntervalSince1970,
                       accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(usage.weeklyResetsAt).timeIntervalSince1970,
                       ISO8601DateFormatter().date(from: "2026-05-17T13:00:00Z")!.timeIntervalSince1970,
                       accuracy: 1)
    }

    func testParsesRelativeResetsWhenNoDataTime() throws {
        let usage = try XCTUnwrap(OllamaUsageMapper.parseSettings(html: relativeHTML, now: now))
        XCTAssertEqual(usage.plan, "Max")
        XCTAssertEqual(usage.sessionPercent, 2.5, accuracy: 0.001)
        XCTAssertEqual(usage.weeklyPercent, 10, accuracy: 0.001)
        // "Resets in 30 minutes" / "Resets in 2 days", resolved against `now`.
        XCTAssertEqual(try XCTUnwrap(usage.sessionResetsAt).timeIntervalSince(now), 30 * 60, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(usage.weeklyResetsAt).timeIntervalSince(now), 2 * 24 * 60 * 60, accuracy: 1)
    }

    func testParsesModernAriaLabelPage() throws {
        // The live 2026 page: lowercase "Cloud usage" heading, lowercase "pro" badge, and a capped
        // Session meter whose percentage survives only in its aria-label (the visible text reads
        // "Weekly limit reached"). This is the shape that used to misclassify a valid session as expired.
        let usage = try XCTUnwrap(OllamaUsageMapper.parseSettings(html: modernSettingsHTML, now: now))
        XCTAssertEqual(usage.plan, "Pro")
        XCTAssertEqual(usage.sessionPercent, 0, accuracy: 0.001)
        XCTAssertEqual(usage.weeklyPercent, 100, accuracy: 0.001)
        let reset = ISO8601DateFormatter().date(from: "2026-07-27T00:00:00Z")!.timeIntervalSince1970
        XCTAssertEqual(try XCTUnwrap(usage.sessionResetsAt).timeIntervalSince1970, reset, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(usage.weeklyResetsAt).timeIntervalSince1970, reset, accuracy: 1)
    }

    func testLooksLikeUsagePageIsCaseInsensitive() {
        XCTAssertTrue(OllamaUsageMapper.looksLikeUsagePage("<h1>Cloud Usage Pro</h1>"))
        XCTAssertTrue(OllamaUsageMapper.looksLikeUsagePage("<h2><span>Cloud usage</span></h2>"))
        XCTAssertTrue(OllamaUsageMapper.looksLikeUsagePage(#"<div aria-label="Session usage 5% used"></div>"#))
        XCTAssertFalse(OllamaUsageMapper.looksLikeUsagePage(loginHTML))
    }

    func testNilWhenNotACloudUsagePage() {
        XCTAssertNil(OllamaUsageMapper.parseSettings(html: loginHTML, now: now))
    }

    func testNilWhenFewerThanTwoMeters() {
        let oneMeter = "<h1>Cloud Usage Pro</h1><span>5% used</span>"
        XCTAssertNil(OllamaUsageMapper.parseSettings(html: oneMeter, now: now))
    }

    func testClampsOutOfRangePercentages() throws {
        // The `N% used` pattern only captures the magnitude (no sign), so both over-range meters clamp
        // to the 0–100 ceiling.
        let over = "<h1>Cloud Usage Pro</h1><span>150% used</span><span>250% used</span>"
        let usage = try XCTUnwrap(OllamaUsageMapper.parseSettings(html: over, now: now))
        XCTAssertEqual(usage.sessionPercent, 100)
        XCTAssertEqual(usage.weeklyPercent, 100)
    }

    func testLinesCarryWindowPeriods() throws {
        let usage = try XCTUnwrap(OllamaUsageMapper.parseSettings(html: settingsHTML, now: now))
        let lines = OllamaUsageMapper.lines(from: usage)
        XCTAssertEqual(progress(lines, "Session")?.periodDurationMs, 5 * 60 * 60 * 1000)
        XCTAssertEqual(progress(lines, "Weekly")?.periodDurationMs, 7 * 24 * 60 * 60 * 1000)
        XCTAssertEqual(progress(lines, "Session")?.format, .percent)
    }

    func testTextFromHtmlStripsScriptsAndDecodesEntities() {
        let dirty = "<div><script>var x = 1;</script>50%&nbsp;used&amp;more</div>"
        let text = OllamaUsageMapper.textFromHtml(dirty)
        XCTAssertTrue(text.contains("50% used&more"))
        XCTAssertFalse(text.contains("script"))
    }

    // MARK: API fallback (future /api/account/usage)

    func testParseAPIUsageNestedObjects() {
        let body = Data(#"""
        {"data":{"plan":"pro","session":{"used_percent":12.5,"resets_at":"2026-05-16T14:55:00Z"},
                  "weekly":{"used_percent":40,"resets_at":"2026-05-17T13:00:00Z"}}}
        """#.utf8)
        let usage = OllamaUsageMapper.parseAPIUsage(body)
        XCTAssertEqual(usage?.plan, "pro")
        XCTAssertEqual(usage?.sessionPercent, 12.5)
        XCTAssertEqual(usage?.weeklyPercent, 40)
        XCTAssertNotNil(usage?.sessionResetsAt)
    }

    func testParseAPIUsageFlatFields() {
        let body = Data(#"{"session_percent":7,"weekly_percent":21}"#.utf8)
        let usage = OllamaUsageMapper.parseAPIUsage(body)
        XCTAssertEqual(usage?.sessionPercent, 7)
        XCTAssertEqual(usage?.weeklyPercent, 21)
        XCTAssertNil(usage?.plan)
    }

    func testParseAPIUsageNilWhenFieldsMissing() {
        XCTAssertNil(OllamaUsageMapper.parseAPIUsage(Data(#"{"unrelated":1}"#.utf8)))
        XCTAssertNil(OllamaUsageMapper.parseAPIUsage(Data("not json".utf8)))
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (format: ProgressFormat, periodDurationMs: Int?)? {
        guard case .progress(_, _, _, let format, _, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (format, periodDurationMs)
    }
}

// MARK: - OllamaProviderTests

@MainActor
final class OllamaProviderTests: XCTestCase {
    func testRefreshMapsSettingsPage() async throws {
        let provider = OllamaProvider(
            authStore: makeAuthStore(cookie: "session-value"),
            usageClient: OllamaUsageClient(http: RoutingHTTPClient { request in
                XCTAssertEqual(request.url, OllamaUsageClient.settingsURL)
                XCTAssertEqual(request.headers["Cookie"], "__Secure-session=session-value")
                return html(settingsHTML)
            }),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
    }

    func testRefreshMapsModernSettingsPage() async throws {
        // Regression for the false "expired": the live page's lowercase "Cloud usage" heading and
        // aria-label meters must map to real Session/Weekly lines, not an auth-expired error.
        let provider = OllamaProvider(
            authStore: makeAuthStore(cookie: "session-value"),
            usageClient: OllamaUsageClient(http: RoutingHTTPClient { _ in html(modernSettingsHTML) }),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
    }

    func testRefreshWithoutCookieOrKeyReportsNotLoggedIn() async {
        let provider = OllamaProvider(
            authStore: OllamaAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: OllamaUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("should not hit the network without credentials")
                return html(settingsHTML)
            })
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.lines.first?.label, "Error")
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testRefreshTreatsLoginPageAsExpiredSession() async {
        // A cookie that no longer authenticates follows the redirect to the login page (no
        // "Cloud Usage" marker) — surfaced as an expired session, not a parse failure.
        let provider = OllamaProvider(
            authStore: makeAuthStore(cookie: "stale"),
            usageClient: OllamaUsageClient(http: RoutingHTTPClient { _ in html(loginHTML) })
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
    }

    func testRefreshOnExplicitRedirectReportsExpiredSession() async {
        let provider = OllamaProvider(
            authStore: makeAuthStore(cookie: "stale"),
            usageClient: OllamaUsageClient(http: RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 302, headers: [:], body: Data())
            })
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .authExpired)
    }

    func testRefreshOnUnparseableCloudUsageReportsDecoding() async {
        // "Cloud Usage" present but no usable meters → the page shape changed, a decoding failure.
        let malformed = "<h1>Cloud Usage Pro</h1><p>no meters here</p>"
        let provider = OllamaProvider(
            authStore: makeAuthStore(cookie: "session-value"),
            usageClient: OllamaUsageClient(http: RoutingHTTPClient { _ in html(malformed) })
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .decoding)
    }

    func testRefreshOnNon2xxReportsRequestFailed() async {
        let provider = OllamaProvider(
            authStore: makeAuthStore(cookie: "session-value"),
            usageClient: OllamaUsageClient(http: RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 500, headers: [:], body: Data())
            })
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .http5xx)
    }

    func testRefreshOnTransportErrorReportsNetwork() async {
        let provider = OllamaProvider(
            authStore: makeAuthStore(cookie: "session-value"),
            usageClient: OllamaUsageClient(http: RoutingHTTPClient { _ in
                throw OllamaUsageError.connectionFailed
            })
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .network)
    }

    func testRefreshFallsBackToAPIKeyWhenNoCookie() async {
        // No session cookie, but an OLLAMA_API_KEY → the future /api/account/usage path.
        let provider = OllamaProvider(
            authStore: OllamaAuthStore(files: FakeFiles(), environment: FakeEnvironment(["OLLAMA_API_KEY": "ollama-key"])),
            usageClient: OllamaUsageClient(http: RoutingHTTPClient { request in
                XCTAssertEqual(request.url, OllamaUsageClient.apiUsageURL)
                XCTAssertEqual(request.headers["Authorization"], "Bearer ollama-key")
                return HTTPResponse(statusCode: 200, headers: [:],
                                    body: Data(#"{"session_percent":3,"weekly_percent":9,"plan":"max"}"#.utf8))
            })
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "max")
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Session"))
    }

    func testHasLocalCredentialsReflectsCookieOrKey() async {
        let withCookie = OllamaProvider(authStore: makeAuthStore(cookie: "c"),
                                        usageClient: OllamaUsageClient(http: RoutingHTTPClient { _ in html(settingsHTML) }))
        let withKey = OllamaProvider(
            authStore: OllamaAuthStore(files: FakeFiles(), environment: FakeEnvironment(["OLLAMA_API_KEY": "k"])),
            usageClient: OllamaUsageClient(http: RoutingHTTPClient { _ in html(settingsHTML) }))
        let neither = OllamaProvider(authStore: OllamaAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
                                     usageClient: OllamaUsageClient(http: RoutingHTTPClient { _ in html(settingsHTML) }))

        let cookieCreds = await withCookie.hasLocalCredentials()
        let keyCreds = await withKey.hasLocalCredentials()
        let neitherCreds = await neither.hasLocalCredentials()
        XCTAssertTrue(cookieCreds)
        XCTAssertTrue(keyCreds)
        XCTAssertFalse(neitherCreds)
    }

    func testAPIKeyManagingDelegatesAndUsesSessionKind() throws {
        let files = FakeFiles()
        let provider = OllamaProvider(
            authStore: OllamaAuthStore(files: files, environment: FakeEnvironment(["OLLAMA_SESSION_COOKIE": "env-cookie"])),
            usageClient: OllamaUsageClient(http: RoutingHTTPClient { _ in html(settingsHTML) })
        )

        if case .sessionKey(let cookieName) = provider.credentialKind {
            XCTAssertEqual(cookieName, "__Secure-session")
        } else {
            XCTFail("Ollama should manage a session key, not an API key")
        }

        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
        XCTAssertEqual(provider.currentAPIKey(), "env-cookie")
        try provider.saveAPIKey("saved-cookie")
        XCTAssertEqual(provider.apiKeyStatus, .overrideActive)
        try provider.deleteAPIKey()
        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
    }

    func testProviderIdentityAndLinks() {
        let provider = OllamaProvider()
        XCTAssertEqual(provider.provider.id, "ollama")
        XCTAssertEqual(provider.provider.displayName, "Ollama")
        XCTAssertEqual(provider.provider.visibleLinks.count, 1)
    }

    private func makeAuthStore(cookie: String) -> OllamaAuthStore {
        OllamaAuthStore(files: FakeFiles(), environment: FakeEnvironment(["OLLAMA_SESSION_COOKIE": cookie]))
    }
}
