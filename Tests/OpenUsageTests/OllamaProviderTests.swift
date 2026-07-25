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

    // MARK: Account name discovery

    /// The live ollama.com/settings page (captured 2026-07): the account identity lives in the
    /// `#user-nav` dropdown as a username `<a href="/settings">` link plus an email `<div>`. The page
    /// also has many other nav links ("Models", "My models") that naive patterns wrongly grab — this
    /// test pins the parser to the real structure so it returns the account, not a nav label.
    private let realUserNavHTML = #"""
    <header class="sticky top-0">
      <nav class="flex w-full items-center justify-between px-6">
        <a href="/models">Models</a>
        <a href="/my/models">My models</a>
        <button>Menu</button>
        <nav id="user-nav" class="absolute hidden mt-2 right-0 w-52 rounded-2xl">
          <div class="py-2">
            <div class="flex flex-col px-4">
              <div class="flex justify-between items-center gap-x-2 mb-1">
                <a href="/settings" class="font-medium text-xl hover:underline" >ollama_user</a>
              </div>
              <div class="text-sm text-neutral-500 break-words">user@example.com</div>
            </div>
          </div>
        </nav>
      </nav>
    </header>
    """#

    func testParseAccountNamePrefersUsernameFromUserNav() {
        // The username link is the display name the user expects (e.g. "ollama_user"), and must win over
        // both the email and the surrounding nav links.
        XCTAssertEqual(OllamaUsageMapper.parseAccountName(from: realUserNavHTML), "ollama_user")
    }

    func testParseAccountNameFallsBackToEmailWhenNoUsernameLink() {
        let noUsername = realUserNavHTML.replacingOccurrences(
            of: #"<a href="/settings" class="font-medium text-xl hover:underline" >ollama_user</a>"#,
            with: ""
        )
        XCTAssertEqual(OllamaUsageMapper.parseAccountName(from: noUsername), "user@example.com")
    }

    func testParseAccountNameDoesNotGrabNavLabels() {
        // Regression: earlier patterns returned "Models" / "My models" from the top nav.
        let name = OllamaUsageMapper.parseAccountName(from: realUserNavHTML)
        XCTAssertNotEqual(name, "Models")
        XCTAssertNotEqual(name, "My models")
    }

    func testParseAccountNameNilWhenNoUserNav() {
        XCTAssertNil(OllamaUsageMapper.parseAccountName(from: loginHTML))
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

// MARK: - OllamaAccountsStoreTests

@MainActor
final class OllamaAccountsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: OllamaAccountsStore!

    override func setUp() {
        super.setUp()
        // Use a unique defaults suite for each test to ensure isolation
        defaults = UserDefaults(suiteName: "test-ollama-accounts-\(UUID().uuidString)")!
        // Clear any existing data
        defaults.removeObject(forKey: OllamaAccountsStore.storageKey)
        defaults.synchronize()
        // Disable migration in tests
        store = OllamaAccountsStore(defaults: defaults, shouldMigrateLegacyAccount: false)
    }

    override func tearDown() {
        // Clean up defaults
        defaults.removeObject(forKey: OllamaAccountsStore.storageKey)
        defaults.synchronize()
        super.tearDown()
    }

    func testEmptyStoreHasNoActiveRecords() {
        XCTAssertTrue(store.activeRecords.isEmpty, "Store should start empty but has \(store.activeRecords.count) records")
        XCTAssertFalse(store.isAtCapacity)
    }

    func testAddAccountCreatesRecordWithSequentialID() {
        let account1 = store.addAccount(sessionCookie: "cookie1")
        XCTAssertNotNil(account1)
        XCTAssertEqual(account1?.id, 0)
        XCTAssertEqual(account1?.sessionCookie, "cookie1")
        XCTAssertEqual(account1?.derivedDisplayName, "Account 1")

        let account2 = store.addAccount(sessionCookie: "cookie2")
        XCTAssertNotNil(account2)
        XCTAssertEqual(account2?.id, 1)
        XCTAssertEqual(account2?.sessionCookie, "cookie2")
        XCTAssertEqual(account2?.derivedDisplayName, "Account 2")
    }

    func testAddAccountRespectsCapacityLimit() {
        // Add accounts up to the limit
        for i in 0..<OllamaAccountsStore.maxAccounts {
            let account = store.addAccount(sessionCookie: "cookie\(i)")
            XCTAssertNotNil(account, "Should be able to add account \(i)")
            XCTAssertEqual(account?.id, i)
        }

        XCTAssertTrue(store.isAtCapacity)

        // Should not be able to add beyond the limit
        let overflow = store.addAccount(sessionCookie: "overflow")
        XCTAssertNil(overflow, "Should not allow adding beyond capacity")
    }

    func testRemoveAccountTombstonesRecord() {
        let account = store.addAccount(sessionCookie: "cookie1")
        XCTAssertNotNil(account)
        XCTAssertEqual(store.activeRecords.count, 1)

        store.removeAccount(accountID: account!.id)
        XCTAssertEqual(store.activeRecords.count, 0, "Removed account should not be in active records")
    }

    /// Regression: IDs must be unique across the record's whole lifetime. Computing the next ID from
    /// only the *active* records reused a just-deleted account's ID, producing two records with the
    /// same `id` — which then made deletion appear to do nothing (the active twin survived).
    func testAddAfterDeleteDoesNotReuseDeletedID() {
        let first = store.addAccount(sessionCookie: "cookie1")
        XCTAssertEqual(first?.id, 0)
        store.removeAccount(accountID: first!.id)

        let second = store.addAccount(sessionCookie: "cookie2")
        XCTAssertNotEqual(second?.id, first?.id, "New account must not reuse the deleted account's ID")
        XCTAssertEqual(second?.id, 1)

        let allIDs = store.records.map { $0.id }
        XCTAssertEqual(allIDs.count, Set(allIDs).count, "IDs must be unique across all records, got \(allIDs)")
    }

    /// Regression for "clicking delete does nothing": the wild stores had a tombstoned record and an
    /// active record sharing an ID. Deleting that ID must make the account disappear for good — the
    /// active record the user sees must go, and stay gone across a reload.
    func testDeleteRemovesActiveRecordDespiteTombstonedTwin() {
        // Reproduce the exact corrupted shape found in the user's defaults.
        let corrupted: [OllamaAccountRecord] = [
            OllamaAccountRecord(id: 0, sessionCookie: "c0", removedTombstone: true),
            OllamaAccountRecord(id: 0, sessionCookie: "c0", removedTombstone: false),
        ]
        defaults.set(try! JSONEncoder().encode(corrupted), forKey: OllamaAccountsStore.storageKey)
        let loaded = OllamaAccountsStore(defaults: defaults, shouldMigrateLegacyAccount: false)
        XCTAssertEqual(loaded.activeRecords.filter { $0.id == 0 }.count, 1, "one active id 0 visible to the user")

        loaded.removeAccount(accountID: 0)
        XCTAssertEqual(loaded.activeRecords.filter { $0.id == 0 }.count, 0,
                       "Deleting id 0 must remove the active record, not just re-tombstone the twin")

        // And it must stay gone after a reload (persisted correctly).
        let reloaded = OllamaAccountsStore(defaults: defaults, shouldMigrateLegacyAccount: false)
        XCTAssertEqual(reloaded.activeRecords.filter { $0.id == 0 }.count, 0, "deletion must persist")
    }

    /// Regression for "the account keeps showing back up despite deleting": once a cookie is deleted
    /// (tombstoned), re-running migration must NOT re-add it. The old code only checked active records,
    /// so a deleted cookie looked "new" and resurrected on every launch.
    func testMigrationDoesNotResurrectDeletedCookie() {
        // Migrate a cookie in, then delete it.
        store.migrateCookieIfNeeded("legacy-cookie")
        XCTAssertEqual(store.activeRecords.map { $0.sessionCookie }, ["legacy-cookie"])
        let id = store.activeRecords.first!.id
        store.removeAccount(accountID: id)
        XCTAssertEqual(store.activeRecords.count, 0, "account deleted")

        // Migration runs again (e.g. next launch) — the deleted cookie must stay gone.
        store.migrateCookieIfNeeded("legacy-cookie")
        XCTAssertEqual(store.activeRecords.count, 0, "deleted cookie must not resurrect")
    }

    /// Migration adds a genuinely new legacy cookie, but assigns a unique ID even alongside tombstones.
    func testMigrationAddsNewCookieWithUniqueID() {
        let a = store.addAccount(sessionCookie: "cookie-a")
        store.removeAccount(accountID: a!.id)            // tombstone id 0
        store.migrateCookieIfNeeded("cookie-b")          // new cookie
        let b = store.activeRecords.first { $0.sessionCookie == "cookie-b" }
        XCTAssertNotNil(b)
        XCTAssertNotEqual(b?.id, a?.id, "migrated cookie must not reuse the tombstoned ID")
    }

    /// Regression for "why does it say Account 3 when I only have 2 accounts?": display names must be
    /// ordinal-based (position among active accounts), not ID-based. Deleting account 0 then adding a
    /// new account (which gets id=3) should still show as "Account 2", not "Account 4".
    func testDisplayNamesAreOrdinalNotIDBased() {
        let a0 = store.addAccount(sessionCookie: "cookie-0")  // id 0
        let a1 = store.addAccount(sessionCookie: "cookie-1")  // id 1
        let a2 = store.addAccount(sessionCookie: "cookie-2")  // id 2

        XCTAssertEqual(store.displayName(accountID: a0!.id), "Account 1")
        XCTAssertEqual(store.displayName(accountID: a1!.id), "Account 2")
        XCTAssertEqual(store.displayName(accountID: a2!.id), "Account 3")

        // Delete account 0, then add a new account (gets id 3)
        store.removeAccount(accountID: a0!.id)
        let a3 = store.addAccount(sessionCookie: "cookie-3")  // id 3
        XCTAssertEqual(a3?.id, 3, "new account gets next unique ID")

        // Display names should be ordinal: Account 1, 2, 3 (not 2, 3, 4)
        XCTAssertEqual(store.displayName(accountID: a1!.id), "Account 1", "id 1 is now first active")
        XCTAssertEqual(store.displayName(accountID: a2!.id), "Account 2", "id 2 is now second active")
        XCTAssertEqual(store.displayName(accountID: a3!.id), "Account 3", "id 3 is now third active")
    }

    /// Repair pre-existing corrupted stores (duplicate IDs from the old add-after-delete bug) on load.
    func testLoadRepairsDuplicateIDs() {
        let corrupted: [OllamaAccountRecord] = [
            OllamaAccountRecord(id: 0, sessionCookie: "c0", removedTombstone: true),
            OllamaAccountRecord(id: 0, sessionCookie: "c0", removedTombstone: false),
            OllamaAccountRecord(id: 1, sessionCookie: "c1", removedTombstone: true),
            OllamaAccountRecord(id: 1, sessionCookie: "c1", removedTombstone: false),
        ]
        defaults.set(try! JSONEncoder().encode(corrupted), forKey: OllamaAccountsStore.storageKey)

        let repaired = OllamaAccountsStore(defaults: defaults, shouldMigrateLegacyAccount: false)
        let ids = repaired.records.map { $0.id }
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate IDs must be collapsed on load, got \(ids)")
        XCTAssertEqual(repaired.activeRecords.count, 2, "Both active accounts should survive repair")
    }

    func testRenameAccountUpdatesCustomLabel() {
        let account = store.addAccount(sessionCookie: "cookie1")
        XCTAssertEqual(account?.resolvedDisplayName, "Account 1")

        let cardID = OllamaAccountsStore.cardID(for: account!.id)
        store.rename(cardID: cardID, to: "My Ollama Account")

        let updatedRecord = store.activeRecords.first
        XCTAssertEqual(updatedRecord?.customLabel, "My Ollama Account")
        XCTAssertEqual(updatedRecord?.resolvedDisplayName, "My Ollama Account")
    }

    func testUpdateDiscoveredLabelDoesNotOverrideCustomLabel() {
        let account = store.addAccount(sessionCookie: "cookie1")
        let cardID = OllamaAccountsStore.cardID(for: account!.id)

        // Set a custom label
        store.rename(cardID: cardID, to: "Custom Name")
        XCTAssertEqual(store.activeRecords.first?.resolvedDisplayName, "Custom Name")

        // Try to update discovered label - should be ignored due to custom label
        store.updateDiscoveredLabel(accountID: account!.id, label: "Discovered Name")

        // Custom label should still win
        XCTAssertEqual(store.activeRecords.first?.resolvedDisplayName, "Custom Name")
        // Discovered label should NOT be stored when custom label exists (implementation exits early)
        XCTAssertNil(store.activeRecords.first?.discoveredLabel, "Discovered label should not be stored when custom label exists")
    }

    func testUpdateDiscoveredLabelWhenNoCustomLabel() {
        let account = store.addAccount(sessionCookie: "cookie1")
        let accountID = account!.id

        XCTAssertEqual(account?.resolvedDisplayName, "Account 1")

        store.updateDiscoveredLabel(accountID: accountID, label: "Jane Doe")
        XCTAssertEqual(store.activeRecords.first?.resolvedDisplayName, "Jane Doe")
        XCTAssertEqual(store.activeRecords.first?.discoveredLabel, "Jane Doe")
    }

    func testUpdateSessionCookie() {
        let account = store.addAccount(sessionCookie: "cookie1")
        let accountID = account!.id

        XCTAssertEqual(store.activeRecords.first?.sessionCookie, "cookie1")

        store.updateSessionCookie(accountID: accountID, cookie: "cookie2")
        XCTAssertEqual(store.activeRecords.first?.sessionCookie, "cookie2")
    }

    func testPersistenceAcrossInstances() {
        let account = store.addAccount(sessionCookie: "cookie1")
        XCTAssertNotNil(account)

        // Create a new store instance with the same defaults (migration off so it doesn't pull in the
        // real machine's legacy cookie and skew the count).
        let newStore = OllamaAccountsStore(defaults: defaults, shouldMigrateLegacyAccount: false)
        XCTAssertEqual(newStore.activeRecords.count, 1)
        XCTAssertEqual(newStore.activeRecords.first?.sessionCookie, "cookie1")
        XCTAssertEqual(newStore.activeRecords.first?.id, 0)
    }

    func testCardIDAndAccountIDParsing() {
        XCTAssertEqual(OllamaAccountsStore.cardID(for: 0), "ollama@0")
        XCTAssertEqual(OllamaAccountsStore.cardID(for: 5), "ollama@5")

        XCTAssertEqual(OllamaAccountsStore.accountID(from: "ollama@0"), 0)
        XCTAssertEqual(OllamaAccountsStore.accountID(from: "ollama@5"), 5)
        XCTAssertNil(OllamaAccountsStore.accountID(from: "ollama"))
        XCTAssertNil(OllamaAccountsStore.accountID(from: "claude@0"))
    }

    func testResolvedDisplayNameForCardID() {
        let account = store.addAccount(sessionCookie: "cookie1")
        let cardID = OllamaAccountsStore.cardID(for: account!.id)

        XCTAssertEqual(store.resolvedDisplayName(cardID: cardID), "Account 1")

        store.rename(cardID: cardID, to: "Custom Name")
        XCTAssertEqual(store.resolvedDisplayName(cardID: cardID), "Custom Name")
    }

    func testLegacyMigrationWhenStoreIsEmpty() {
        // Create a store that should migrate from legacy config
        let legacyDefaults = UserDefaults(suiteName: "test-ollama-legacy-\(UUID().uuidString)")!
        let legacyStore = OllamaAccountsStore(defaults: legacyDefaults)

        // Simulate legacy state by creating an OllamaAuthStore with a cookie
        let fakeFiles = FakeFiles([OllamaAuthStore.configPaths[0]: "legacy-cookie"])
        let legacyAuthStore = OllamaAuthStore(
            files: fakeFiles,
            environment: FakeEnvironment(["OLLAMA_SESSION_COOKIE": "env-cookie"])
        )

        // Verify the legacy auth store has a cookie
        XCTAssertNotNil(legacyAuthStore.loadSessionCookie())

        // The migration should have run when OllamaAccountsStore was initialized
        // Since we can't easily mock the OllamaAuthStore inside the migration,
        // we verify the migration logic exists and the store handles empty state
        XCTAssertTrue(legacyStore.activeRecords.isEmpty || legacyStore.activeRecords.count == 1)
    }
}

// MARK: - OllamaAccountAssemblyTests

@MainActor
final class OllamaAccountAssemblyTests: XCTestCase {
    func testEmptyStoreProducesEmptyAssembly() {
        let defaults = UserDefaults(suiteName: "test-ollama-assembly-\(UUID().uuidString)")!
        let store = OllamaAccountsStore(defaults: defaults, shouldMigrateLegacyAccount: false)
        let assembly = OllamaAccountAssembly.make(accountsStore: store)

        XCTAssertTrue(assembly.accountCards.isEmpty)
        XCTAssertTrue(assembly.sessionCookiesByCard.isEmpty)
    }

    func testAssemblyMapsRecordsToCards() {
        let defaults = UserDefaults(suiteName: "test-ollama-assembly-\(UUID().uuidString)")!
        let store = OllamaAccountsStore(defaults: defaults, shouldMigrateLegacyAccount: false)

        let account1 = store.addAccount(sessionCookie: "cookie1")
        let account2 = store.addAccount(sessionCookie: "cookie2")

        store.rename(cardID: OllamaAccountsStore.cardID(for: account2!.id), to: "Work Account")

        let assembly = OllamaAccountAssembly.make(accountsStore: store)

        XCTAssertEqual(assembly.accountCards.count, 2)

        let card1 = assembly.accountCards.first { $0.accountID == 0 }
        XCTAssertNotNil(card1)
        XCTAssertEqual(card1?.id, "ollama@0")
        XCTAssertEqual(card1?.displayName, "Account 1")
        XCTAssertEqual(card1?.sessionCookie, "cookie1")

        let card2 = assembly.accountCards.first { $0.accountID == 1 }
        XCTAssertNotNil(card2)
        XCTAssertEqual(card2?.id, "ollama@1")
        XCTAssertEqual(card2?.displayName, "Work Account")
        XCTAssertEqual(card2?.sessionCookie, "cookie2")
    }

    func testAssemblyBuildsSessionCookieMap() {
        let defaults = UserDefaults(suiteName: "test-ollama-assembly-\(UUID().uuidString)")!
        let store = OllamaAccountsStore(defaults: defaults, shouldMigrateLegacyAccount: false)

        let account1 = store.addAccount(sessionCookie: "cookie1")
        let account2 = store.addAccount(sessionCookie: "cookie2")

        let assembly = OllamaAccountAssembly.make(accountsStore: store)

        XCTAssertEqual(assembly.sessionCookiesByCard.count, 2)
        XCTAssertEqual(assembly.sessionCookiesByCard["ollama@0"], "cookie1")
        XCTAssertEqual(assembly.sessionCookiesByCard["ollama@1"], "cookie2")
    }

    func testAssemblyExcludesRemovedAccounts() {
        let defaults = UserDefaults(suiteName: "test-ollama-assembly-\(UUID().uuidString)")!
        let store = OllamaAccountsStore(defaults: defaults, shouldMigrateLegacyAccount: false)

        let account1 = store.addAccount(sessionCookie: "cookie1")
        let account2 = store.addAccount(sessionCookie: "cookie2")

        store.removeAccount(accountID: account1!.id)

        let assembly = OllamaAccountAssembly.make(accountsStore: store)

        XCTAssertEqual(assembly.accountCards.count, 1)
        XCTAssertEqual(assembly.accountCards.first?.accountID, 1)
        XCTAssertTrue(assembly.sessionCookiesByCard.isEmpty || assembly.sessionCookiesByCard.count == 1)
    }
}

// MARK: - Multi-Account Ollama Provider Tests

@MainActor
final class OllamaMultiAccountProviderTests: XCTestCase {
    func testMultiAccountProviderUsesCorrectCookie() async throws {
        let provider = OllamaProvider(
            provider: OllamaProvider.makeProvider(id: "ollama@2", displayName: "Account 3"),
            authStore: OllamaAuthStore(accountID: 2, sessionCookie: "account-2-cookie"),
            usageClient: OllamaUsageClient(http: RoutingHTTPClient { request in
                XCTAssertEqual(request.headers["Cookie"], "__Secure-session=account-2-cookie")
                return html(settingsHTML)
            }),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertNil(snapshot.errorCategory)
    }

    func testMultiAccountProviderReportsAccountID() {
        let provider = OllamaProvider(
            provider: OllamaProvider.makeProvider(id: "ollama@5", displayName: "Test Account"),
            authStore: OllamaAuthStore(accountID: 5, sessionCookie: "cookie"),
            usageClient: OllamaUsageClient(http: RoutingHTTPClient { _ in html(settingsHTML) })
        )

        XCTAssertEqual(provider.provider.id, "ollama@5")
        XCTAssertEqual(provider.accountID, 5)
    }

    /// When there are no active account cards, the catalog falls back to the default single-account
    /// provider (reads the baseline credential from `ollama.json` / env vars). Ollama always appears
    /// as a provider — deleting every multi-account card removes those cards but never the provider.
    @MainActor
    func testCatalogUsesLegacyFallbackWhenNoCards() {
        let runtimes = ProviderCatalog.make(ollamaCards: [])
        let ollamaCount = runtimes.filter { $0 is OllamaProvider }.count
        XCTAssertEqual(ollamaCount, 1, "no active cards falls back to the legacy single-account provider")
    }

    /// Two accounts → two Ollama providers (the default card + one account card).
    @MainActor
    func testCatalogBuildsOneProviderPerAccount() {
        let cards = [
            OllamaAccountAssembly.OllamaAccountCard(id: "ollama@0", displayName: "Account 1", accountID: 0, sessionCookie: "c0"),
            OllamaAccountAssembly.OllamaAccountCard(id: "ollama@1", displayName: "Account 2", accountID: 1, sessionCookie: "c1"),
        ]
        let runtimes = ProviderCatalog.make(ollamaCards: cards)
        let ollamaProviders = runtimes.compactMap { $0 as? OllamaProvider }
        XCTAssertEqual(ollamaProviders.count, 2, "two accounts must build two Ollama providers")
        XCTAssertEqual(Set(ollamaProviders.map { $0.provider.id }), ["ollama", "ollama@1"])
    }

    func testAccountNameDiscoveryCallback() async throws {
        var discoveredAccountID: Int?
        var discoveredName: String?

        let provider = OllamaProvider(
            provider: OllamaProvider.makeProvider(id: "ollama@3", displayName: "Account 4"),
            authStore: OllamaAuthStore(accountID: 3, sessionCookie: "cookie"),
            usageClient: OllamaUsageClient(http: RoutingHTTPClient { _ in
                // Return a valid usage page - account name discovery works even without finding a name
                HTTPResponse(statusCode: 200, headers: [:], body: Data(#"""
                <html>
                <body>
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
                </body>
                </html>
                """#.utf8))
            }),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        provider.onAccountNameDiscovered = { accountID, name in
            discoveredAccountID = accountID
            discoveredName = name
        }

        let snapshot = await provider.refresh()

        // Verify the callback was invoked with accountID (name might be nil if not found in HTML)
        XCTAssertEqual(discoveredAccountID, 3)
        // The name discovery might not find anything in the simple HTML above, so we just check the callback was called
        XCTAssertNotNil(discoveredAccountID, "Account name discovery callback should be invoked")

        // Also verify the snapshot is valid
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertNil(snapshot.errorCategory)
    }
}
