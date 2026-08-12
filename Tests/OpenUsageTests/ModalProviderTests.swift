import Foundation
import XCTest
@testable import OpenUsage

private let workspacesJSON = """
[
  {
    "workspaceId": "ac-bkkEYIWiPi974li4UNaym9",
    "memberId": "me-JemsXAHVHUolTkVS02KK1H",
    "username": "cbrown350",
    "memberRole": "MEMBER_ROLE_OWNER",
    "cycleUsage": 1.35,
    "cycleCredits": 30.0,
    "cycleSpendLimit": 30.0,
    "cycleCapDollars": 20.0,
    "grantedCycleCredits": 30.0,
    "cycleBudgetDollars": 30.0,
    "planType": "PLAN_STARTER",
    "memberDisplayName": "Clifford B. Brown"
  }
]
"""

private let billingCyclesJSON = """
{"cycles":[{"start":1785542400.0,"end":1788220800.0,"isCurrent":true}]}
"""

private func data(_ string: String) -> Data { Data(string.utf8) }
private func jsonResponse(_ string: String) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: data(string))
}

// MARK: - ModalUsageMapperTests

final class ModalUsageMapperTests: XCTestCase {
    func testMapsSpendCreditsAndPlan() throws {
        let mapped = try ModalUsageMapper.map(
            workspacesBody: data(workspacesJSON),
            cyclesBody: data(billingCyclesJSON)
        )

        XCTAssertEqual(mapped.plan, "Starter")

        let spend = try XCTUnwrap(progress(mapped.lines, "Spend"))
        XCTAssertEqual(spend.used, 1.35, accuracy: 0.0001)
        XCTAssertEqual(spend.limit, 30.0, accuracy: 0.0001)
        XCTAssertEqual(spend.format, .dollars)
        XCTAssertEqual(spend.resetsAt, Date(timeIntervalSince1970: 1788220800.0))

        let credits = try XCTUnwrap(values(mapped.lines, "Credits").first)
        XCTAssertEqual(credits.number, 28.65, accuracy: 0.0001)
        XCTAssertEqual(credits.kind, .dollars)
    }

    func testFallsBackToCycleCreditsWhenGrantedAbsent() throws {
        let body = data(#"[{"username":"u","cycleUsage":5,"cycleCredits":10,"cycleSpendLimit":50,"planType":"PLAN_TEAM"}]"#)
        let usage = try ModalUsageMapper.parse(workspacesBody: body, cyclesBody: nil)
        XCTAssertEqual(usage.creditsRemaining, 5, accuracy: 0.0001) // 10 - 5
        XCTAssertEqual(usage.plan, "Team")
    }

    func testCreditsFloorAtZero() throws {
        let body = data(#"[{"username":"u","cycleUsage":40,"grantedCycleCredits":30,"cycleSpendLimit":100}]"#)
        let usage = try ModalUsageMapper.parse(workspacesBody: body, cyclesBody: nil)
        XCTAssertEqual(usage.creditsRemaining, 0, accuracy: 0.0001)
        XCTAssertNil(usage.plan)
    }

    func testResetDateAbsentWhenNoCurrentCycle() throws {
        // A non-2xx / malformed cycles body (best-effort) just means no reset date.
        let usage = try ModalUsageMapper.parse(workspacesBody: data(workspacesJSON), cyclesBody: nil)
        XCTAssertNil(usage.resetsAt)
    }

    func testInvalidWorkspacesBodyThrows() {
        XCTAssertThrowsError(try ModalUsageMapper.map(workspacesBody: data("{}"), cyclesBody: nil)) {
            XCTAssertEqual($0 as? ModalUsageError, .invalidResponse)
        }
    }

    func testMissingSpendThrows() {
        let body = data(#"[{"username":"u","planType":"PLAN_STARTER"}]"#)
        XCTAssertThrowsError(try ModalUsageMapper.parse(workspacesBody: body, cyclesBody: nil)) {
            XCTAssertEqual($0 as? ModalUsageError, .invalidResponse)
        }
    }

    func testWorkspaceUsername() throws {
        XCTAssertEqual(ModalUsageMapper.workspaceUsername(from: data(workspacesJSON)), "cbrown350")
        XCTAssertNil(ModalUsageMapper.workspaceUsername(from: data("{}")))
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, format: ProgressFormat, resetsAt: Date?)? {
        guard case .progress(_, let used, let limit, let format, let resetsAt, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, format, resetsAt)
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue] {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            XCTFail("expected a values line for \(label)")
            return []
        }
        return values
    }
}

// MARK: - ModalAuthStoreTests

final class ModalAuthStoreTests: XCTestCase {
    func testExtractsBareCookieValue() {
        XCTAssertEqual(
            ModalAuthStore.extractCookieValue(from: "se-abc123:xx-def456"),
            "se-abc123:xx-def456"
        )
    }

    func testExtractsFromCookieHeader() {
        XCTAssertEqual(
            ModalAuthStore.extractCookieValue(from: "modal-session=se-abc123"),
            "se-abc123"
        )
        XCTAssertEqual(
            ModalAuthStore.extractCookieValue(from: "Cookie: other=1; modal-session=se-abc123; more=2"),
            "se-abc123"
        )
    }

    func testRejectsHeaderWithoutSessionCookie() {
        XCTAssertNil(ModalAuthStore.extractCookieValue(from: "other=1; session=2"))
    }

    func testRejectsEmptyAndControl() {
        XCTAssertNil(ModalAuthStore.extractCookieValue(from: "   "))
        XCTAssertNil(ModalAuthStore.extractCookieValue(from: "se-with\u{000A}newline"))
    }

    func testLoadsFromConfigFile() {
        let files = FakeFiles(["~/.config/openusage/modal.json": #"{"apiKey":"modal-session=se-file"}"#])
        let store = ModalAuthStore(files: files, environment: FakeEnvironment())
        XCTAssertEqual(store.loadSessionCookie()?.sessionCookie, "se-file")
    }

    func testLoadsFromEnvironment() {
        let env = FakeEnvironment(["MODAL_SESSION_COOKIE": "se-env"])
        let store = ModalAuthStore(files: FakeFiles(), environment: env)
        XCTAssertEqual(store.loadSessionCookie()?.sessionCookie, "se-env")
    }
}

// MARK: - ModalProviderTests

@MainActor
final class ModalProviderTests: XCTestCase {
    private func makeAuthStore() -> ModalAuthStore {
        ModalAuthStore(
            files: FakeFiles(["~/.config/openusage/modal.json": #"{"apiKey":"se-cookie"}"#]),
            environment: FakeEnvironment()
        )
    }

    func testRefreshMapsBothRowsAndPlan() async throws {
        let provider = ModalProvider(
            authStore: makeAuthStore(),
            usageClient: ModalUsageClient(http: RoutingHTTPClient { request in
                XCTAssertEqual(request.headers["Cookie"], "modal-session=se-cookie")
                if request.url == ModalUsageClient.workspacesURL {
                    return jsonResponse(workspacesJSON)
                }
                return jsonResponse(billingCyclesJSON)
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Starter")
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Spend"))
        XCTAssertNotNil(snapshot.line(label: "Credits"))
    }

    func testRefreshSurvivesBillingCyclesFailure() async {
        // The billing-cycles call is best-effort (reset date only) — a failure there must not blank
        // out the spend/credits rows.
        let provider = ModalProvider(
            authStore: makeAuthStore(),
            usageClient: ModalUsageClient(http: RoutingHTTPClient { request in
                if request.url == ModalUsageClient.workspacesURL {
                    return jsonResponse(workspacesJSON)
                }
                return HTTPResponse(statusCode: 500, headers: [:], body: data("{}"))
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertFalse(snapshot.lines.contains { $0.isError })
        XCTAssertEqual(snapshot.plan, "Starter")
        XCTAssertNotNil(snapshot.line(label: "Spend"))
        XCTAssertNotNil(snapshot.line(label: "Credits"))
    }

    func testRefreshWithoutCookieReportsNotLoggedIn() async {
        let provider = ModalProvider(
            authStore: ModalAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: ModalUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("should not hit the network without a cookie")
                return jsonResponse("{}")
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertTrue(snapshot.lines.contains { $0.isError })
    }

    func testRefresh401ReportsSessionExpired() async {
        let provider = ModalProvider(
            authStore: makeAuthStore(),
            usageClient: ModalUsageClient(http: RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 401, headers: [:], body: data(#"{"description":"Unauthorized","status":401}"#))
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertTrue(snapshot.lines.contains { $0.isError })
    }

    func testHasLocalCredentialsTrueWithCookie() async {
        let provider = ModalProvider(authStore: makeAuthStore())
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testHasLocalCredentialsFalseWithoutCookie() async {
        let provider = ModalProvider(
            authStore: ModalAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertFalse(has)
    }
}
