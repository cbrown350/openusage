import Foundation

/// Normalized Modal workspace billing. Modal meters spend against the free monthly credit grant, so
/// "Spend" is `cycleUsage` of a `cycleSpendLimit` cap (the dashboard's own meter is
/// `min(cycleUsage / cycleSpendLimit, 1)`), and "Credits" is what remains of the grant.
struct ModalUsage: Hashable, Sendable {
    var plan: String?
    var spend: Double
    var spendLimit: Double
    var creditsRemaining: Double
    var resetsAt: Date?
}

/// Builds metric lines from the Modal dashboard's REST payloads. `GET /api/user/workspaces` returns an
/// array whose first element carries the workspace billing object (`cycleUsage`, `grantedCycleCredits`,
/// `cycleSpendLimit`, `planType`, `username`); `GET /api/workspaces/{username}/billing-cycles` returns
/// `{cycles:[{start,end,isCurrent}]}`. The mapper is pure (no I/O) so it tests cleanly against
/// captured payloads.
enum ModalUsageMapper {
    /// `(plan, lines)` from the workspaces payload plus the best-effort billing-cycles payload
    /// (reset date only).
    static func map(workspacesBody: Data, cyclesBody: Data?) throws -> (plan: String?, lines: [MetricLine]) {
        let usage = try parse(workspacesBody: workspacesBody, cyclesBody: cyclesBody)
        return (usage.plan, lines(from: usage))
    }

    /// The Spend meter (dollars of the spend limit) plus the Credits row (dollars remaining of the
    /// monthly grant).
    static func lines(from usage: ModalUsage) -> [MetricLine] {
        [
            .progress(label: "Spend", used: usage.spend, limit: usage.spendLimit, format: .dollars,
                      resetsAt: usage.resetsAt),
            .values(label: "Credits", values: [
                MetricValue(number: usage.creditsRemaining, kind: .dollars)
            ])
        ]
    }

    /// The workspace billing object from `/api/user/workspaces`, joined with the current cycle's reset
    /// date from `/api/workspaces/{username}/billing-cycles` when available.
    static func parse(workspacesBody: Data, cyclesBody: Data?) throws -> ModalUsage {
        // The endpoint returns a JSON array; take the first (primary) workspace object.
        guard let root = try? JSONSerialization.jsonObject(with: workspacesBody),
              let array = root as? [[String: Any]]
        else { throw ModalUsageError.invalidResponse }
        let matching = array.first { ProviderParse.number($0["cycleUsage"]) != nil } ?? array.first
        guard let workspace = matching else { throw ModalUsageError.noWorkspace }

        guard let spend = ProviderParse.number(workspace["cycleUsage"]),
              let spendLimit = ProviderParse.number(workspace["cycleSpendLimit"])
        else { throw ModalUsageError.invalidResponse }

        let grantedCredits = ProviderParse.number(workspace["grantedCycleCredits"])
            ?? ProviderParse.number(workspace["cycleCredits"]) ?? 0
        // The dashboard's remaining-credits readout: the grant minus what has been used, floored at 0.
        let creditsRemaining = max(grantedCredits - spend, 0)

        return ModalUsage(
            plan: planName(from: workspace),
            spend: spend,
            spendLimit: spendLimit,
            creditsRemaining: creditsRemaining,
            resetsAt: currentCycleEnd(from: cyclesBody)
        )
    }

    /// The workspace `username` used to route the per-workspace endpoints.
    static func workspaceUsername(from workspacesBody: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: workspacesBody),
              let array = root as? [[String: Any]]
        else { return nil }
        return (array.first?["username"] as? String)?.nilIfEmpty
    }

    /// `resetAt` for the current billing cycle: the `end` of the entry flagged `isCurrent`.
    static func currentCycleEnd(from cyclesBody: Data?) -> Date? {
        guard let body = cyclesBody,
              let root = ProviderParse.jsonObject(body),
              let cycles = root["cycles"] as? [[String: Any]]
        else { return nil }
        let current = cycles.first(where: { ProviderParse.bool($0["isCurrent"]) ?? false }) ?? cycles.first
        guard let end = current.flatMap({ ProviderParse.number($0["end"]) }), end > 0 else { return nil }
        return Date(timeIntervalSince1970: end)
    }

    /// Title-case the plan: `PLAN_STARTER` → "Starter".
    static func planName(from workspace: [String: Any]) -> String? {
        guard let raw = (workspace["planType"] as? String)?.nilIfEmpty else { return nil }
        let name = raw.hasPrefix("PLAN_") ? String(raw.dropFirst("PLAN_".count)) : raw
        return name.titleCased(separator: { !$0.isLetter && !$0.isNumber }, lowercasingTail: true)
    }
}
