import Foundation

/// Normalized Qwen Token Plan usage. Percentages are 0–100 "used" values (the API reports a 0–1
/// fraction; the meters show used-of-limit like every other provider).
struct QwenUsage: Hashable, Sendable {
    var fiveHourPercent: Double
    var weeklyPercent: Double
    var fiveHourResetsAt: Date?
    var weeklyResetsAt: Date?
}

/// Builds metric lines from Qwen Cloud's Token Plan usage. The billing console is a SPA that posts to
/// Alibaba's "zelda" gateway; every response wraps the real payload in a
/// `data → DataV2 → data → data` envelope with a `code: "SUCCESS"` marker. The usage call reports the
/// 5-hour and weekly windows as `per5HourPercentage` / `per1WeekPercentage` fractions with epoch-ms
/// reset times; the subscription call reports the plan tier as `specCode` (lite / standard / pro). The
/// mapper is pure (no I/O) so it tests cleanly against captured payloads.
enum QwenUsageMapper {
    static let fiveHourPeriodMs = 5 * 60 * 60 * 1000
    static let weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000

    /// `(plan, lines)` from the usage payload plus the best-effort subscription payload (plan tier only).
    static func map(usageBody: Data, subscriptionBody: Data?) throws -> (plan: String?, lines: [MetricLine]) {
        let usage = try parseUsage(usageBody)
        let plan = subscriptionBody.flatMap { planName(from: $0) }
        return (plan, lines(from: usage))
    }

    /// The 5-Hour Window + Weekly percent meters for a parsed usage value.
    static func lines(from usage: QwenUsage) -> [MetricLine] {
        [
            .progress(label: "5-Hour Window", used: usage.fiveHourPercent, limit: 100, format: .percent,
                      resetsAt: usage.fiveHourResetsAt, periodDurationMs: fiveHourPeriodMs),
            .progress(label: "Weekly", used: usage.weeklyPercent, limit: 100, format: .percent,
                      resetsAt: usage.weeklyResetsAt, periodDurationMs: weeklyPeriodMs)
        ]
    }

    /// The usage windows from a `…/v2/usage` payload. The API reports usage as a 0–1 fraction (e.g.
    /// `0.2685` = 26.85% used). The 5-hour window fields are optional — Qwen omits them when no session
    /// window is active — so a missing `per5HourPercentage` reads as 0% rather than a parse failure.
    /// The weekly window is always present; missing weekly values are an invalid response.
    static func parseUsage(_ body: Data) throws -> QwenUsage {
        guard let payload = dataPayload(body),
              let weeklyFraction = ProviderParse.number(payload["per1WeekPercentage"])
        else {
            throw QwenUsageError.invalidResponse
        }
        let fiveHourFraction = ProviderParse.number(payload["per5HourPercentage"]) ?? 0
        return QwenUsage(
            fiveHourPercent: ProviderParse.clampPercent(fiveHourFraction * 100),
            weeklyPercent: ProviderParse.clampPercent(weeklyFraction * 100),
            fiveHourResetsAt: epochMsDate(payload["per5HourResetTime"]),
            weeklyResetsAt: epochMsDate(payload["per1WeekResetTime"])
        )
    }

    /// The plan tier name from a `…/v2/subscription` payload — `specCode` ("lite") title-cased ("Lite").
    static func planName(from body: Data) -> String? {
        guard let payload = dataPayload(body),
              let specCode = (payload["specCode"] as? String)?.nilIfEmpty
        else { return nil }
        return specCode.titleCased(separator: { !$0.isLetter && !$0.isNumber }, lowercasingTail: true)
    }

    // MARK: - Envelope

    /// Whether a gateway body reports the ticket as unauthenticated. The gateway answers HTTP 200 even
    /// when the session is dead, signalling it only in the envelope as
    /// `data.errorCode: "BailianGateway.Login.NotLogined"` — so this is the only way to tell an expired
    /// ticket apart from a genuine parse failure.
    static func isNotLoggedIn(_ body: Data) -> Bool {
        guard let root = ProviderParse.jsonObject(body),
              let data = root["data"] as? [String: Any],
              let errorCode = data["errorCode"] as? String
        else { return false }
        return errorCode.contains("Login.NotLogined")
    }

    /// Unwrap the gateway envelope, returning the innermost payload only when it reports success.
    ///
    /// Two shapes are accepted because the console changed the wire format: the original nested
    /// `data → DataV2 → data → data`, and the current flatter `data → data` (no `DataV2` wrapper). A
    /// non-success envelope (e.g. a rejected ticket) yields `nil`, so the caller surfaces a typed error
    /// instead of mapping garbage.
    static func dataPayload(_ body: Data) -> [String: Any]? {
        guard let root = ProviderParse.jsonObject(body),
              let data = root["data"] as? [String: Any]
        else { return nil }

        // Prefer the `DataV2` wrapper when present; otherwise the envelope is already the inner object.
        let inner = (data["DataV2"] as? [String: Any])?["data"] as? [String: Any] ?? data

        let succeeded = (inner["code"] as? String) == "SUCCESS" || (ProviderParse.bool(inner["success"]) ?? false)
        guard succeeded else { return nil }
        return inner["data"] as? [String: Any]
    }

    /// An epoch-milliseconds field as a `Date` (the gateway's reset-time format).
    private static func epochMsDate(_ value: Any?) -> Date? {
        guard let ms = ProviderParse.number(value), ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
