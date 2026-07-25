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
    /// `0.2685` = 26.85% used); missing percentages are an invalid response rather than zero usage.
    static func parseUsage(_ body: Data) throws -> QwenUsage {
        guard let payload = dataPayload(body),
              let fiveHourFraction = ProviderParse.number(payload["per5HourPercentage"]),
              let weeklyFraction = ProviderParse.number(payload["per1WeekPercentage"])
        else {
            throw QwenUsageError.invalidResponse
        }
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

    /// Unwrap `data → DataV2 → data → data`, returning the innermost payload only when the gateway
    /// reports success (`code: "SUCCESS"` or `success: true`). A non-success envelope (e.g. a rejected
    /// ticket) yields `nil`, so the caller surfaces a typed error instead of mapping garbage.
    static func dataPayload(_ body: Data) -> [String: Any]? {
        guard let root = ProviderParse.jsonObject(body),
              let data = root["data"] as? [String: Any],
              let dataV2 = data["DataV2"] as? [String: Any],
              let inner = dataV2["data"] as? [String: Any]
        else { return nil }
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
