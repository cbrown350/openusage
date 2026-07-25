import Foundation

/// Normalized Ollama Cloud usage, parsed from the account settings page (or a future JSON endpoint).
/// Percentages are 0–100 "used" values, matching the meters on ollama.com/settings.
struct OllamaUsage: Hashable, Sendable {
    var plan: String?
    var sessionPercent: Double
    var weeklyPercent: Double
    var sessionResetsAt: Date?
    var weeklyResetsAt: Date?
}

/// Builds metric lines from Ollama Cloud's account usage. Ollama documents no cloud quota API yet — its
/// pricing page points users at the web settings page — so the primary source is a scrape of the
/// authenticated `https://ollama.com/settings` HTML, porting the legacy Tauri plugin shipped in PR #470:
/// the first `N% used` is the Session meter (5-hour window), the second is the Weekly meter (7-day
/// window), `data-time="…"` carries ISO-8601 reset timestamps, and the plan label follows the
/// "Cloud Usage" heading. A future `GET /api/account/usage` (JSON) is parsed too, so the provider can
/// prefer it once Ollama ships it. The mapper is pure (no I/O) so it tests cleanly against fixtures.
enum OllamaUsageMapper {
    static let sessionPeriodMs = 5 * 60 * 60 * 1000
    static let weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000

    /// The Session + Weekly percent meters for a parsed usage value.
    static func lines(from usage: OllamaUsage) -> [MetricLine] {
        [
            .progress(label: "Session", used: usage.sessionPercent, limit: 100, format: .percent,
                      resetsAt: usage.sessionResetsAt, periodDurationMs: sessionPeriodMs),
            .progress(label: "Weekly", used: usage.weeklyPercent, limit: 100, format: .percent,
                      resetsAt: usage.weeklyResetsAt, periodDurationMs: weeklyPeriodMs)
        ]
    }

    /// Whether the HTML is an authenticated Cloud Usage settings page (vs. a redirected login page, which
    /// has neither the "Cloud usage" heading nor the usage meters). The heading's casing varies across
    /// page versions ("Cloud Usage" → "Cloud usage"), so match case-insensitively; the meters'
    /// `aria-label`s are an equally stable structural marker if the heading is ever renamed.
    static func looksLikeUsagePage(_ html: String) -> Bool {
        html.range(of: "cloud usage", options: .caseInsensitive) != nil
            || html.range(of: #"aria-label="session usage"#, options: .caseInsensitive) != nil
    }

    /// Parse the authenticated settings-page HTML. Returns `nil` when the page isn't a logged-in Cloud
    /// Usage page (no usage marker) or the two meters can't be found — the provider turns that into a
    /// typed "could not parse" error rather than blank meters.
    static func parseSettings(html: String, now: Date) -> OllamaUsage? {
        guard looksLikeUsagePage(html) else { return nil }
        let text = textFromHtml(html)

        // Prefer the meters' accessible labels — `aria-label="Session usage N% used"` survives in every
        // meter state, including "limit reached", where the visible text swaps "N% used" for a status
        // phrase (the value then lives only in the attribute, which `textFromHtml` strips). Fall back to
        // the visible "N% used" scan for pages or fixtures that lack aria-labels.
        let percentages = ariaLabelPercentages(html) ?? visibleTextPercentages(text)
        guard percentages.count == 2 else { return nil }

        // Reset timestamps ride on `data-time` in the raw HTML (ISO-8601); the first is the Session
        // window's, the second the Weekly window's. When absent, fall back to the relative
        // "Resets in …" text within each section, resolved against `now`.
        let resetValues = group1Matches(of: dataTimeRegex, in: html)
        let sessionSection = sectionBetween(text, start: "Session usage", end: "Weekly usage")
        let weeklySection = sectionBetween(text, start: "Weekly usage", end: "Notify me")

        return OllamaUsage(
            plan: planFromText(text),
            sessionPercent: percentages[0],
            weeklyPercent: percentages[1],
            sessionResetsAt: resetDate(resetValues[safe: 0]) ?? relativeReset(in: sessionSection, now: now),
            weeklyResetsAt: resetDate(resetValues[safe: 1]) ?? relativeReset(in: weeklySection, now: now)
        )
    }

    /// Parse a future `GET /api/account/usage` JSON body — the fallback the provider uses with an
    /// `OLLAMA_API_KEY` when no settings-page cookie exists. Tolerates the shapes the legacy plugin
    /// accepted: nested `session`/`weekly` objects (with `used_percent`-style keys and `resets_at`), or
    /// flat `session_percent`/`weekly_percent` fields at the root (optionally under a `data` wrapper).
    static func parseAPIUsage(_ body: Data) -> OllamaUsage? {
        guard let root = ProviderParse.jsonObject(body) else { return nil }
        let container = (root["data"] as? [String: Any]) ?? root

        let session = nestedObject(container, keys: ["session", "session_usage", "sessionUsage"])
        let weekly = nestedObject(container, keys: ["weekly", "weekly_usage", "weeklyUsage"])

        let sessionPercent = clampPercent(
            session.flatMap { firstNumber($0, keys: ["used_percent", "usedPercent", "percent", "percentage"]) }
                ?? ProviderParse.number(container["session_percent"] ?? container["sessionPercent"])
        )
        let weeklyPercent = clampPercent(
            weekly.flatMap { firstNumber($0, keys: ["used_percent", "usedPercent", "percent", "percentage"]) }
                ?? ProviderParse.number(container["weekly_percent"] ?? container["weeklyPercent"])
        )
        guard let sessionPercent, let weeklyPercent else { return nil }

        let planRaw = (container["plan"] ?? container["tier"] ?? container["subscription"]) as? String
        return OllamaUsage(
            plan: planRaw?.nilIfEmpty,
            sessionPercent: sessionPercent,
            weeklyPercent: weeklyPercent,
            sessionResetsAt: resetDate(
                (session?["resets_at"] ?? session?["resetsAt"] ?? container["session_resets_at"]) as? String
            ),
            weeklyResetsAt: resetDate(
                (weekly?["resets_at"] ?? weekly?["resetsAt"] ?? container["weekly_resets_at"]) as? String
            )
        )
    }

    // MARK: - Percentages

    /// The Session + Weekly percents read from the meters' `aria-label="<Meter> usage N% used"`
    /// attributes — the canonical values, present even when a capped meter's visible text shows a status
    /// phrase ("Weekly limit reached") instead of a percentage. `nil` unless both meters are found, so
    /// the caller falls back to the visible-text scan.
    private static func ariaLabelPercentages(_ html: String) -> [Double]? {
        guard
            let sessionRaw = group1Matches(of: sessionAriaRegex, in: html).first,
            let weeklyRaw = group1Matches(of: weeklyAriaRegex, in: html).first,
            let session = ProviderParse.number(sessionRaw),
            let weekly = ProviderParse.number(weeklyRaw)
        else { return nil }
        return [ProviderParse.clampPercent(session), ProviderParse.clampPercent(weekly)]
    }

    /// The first two visible `N% used` values in the tag-stripped text (Session then Weekly) — the
    /// fallback for pages/fixtures whose meters carry no `aria-label`.
    private static func visibleTextPercentages(_ text: String) -> [Double] {
        var percentages: [Double] = []
        for raw in group1Matches(of: percentUsedRegex, in: text) {
            guard let value = ProviderParse.number(raw) else { continue }
            percentages.append(ProviderParse.clampPercent(value))
            if percentages.count == 2 { break }
        }
        return percentages
    }

    // MARK: - HTML → text

    /// Strip scripts/styles/tags, decode the common HTML entities, and collapse whitespace — turning the
    /// settings page into the flat text the `N% used` / plan / "Resets in" patterns match against.
    static func textFromHtml(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func decodeEntities(_ text: String) -> String {
        var s = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        s = replaceGroup1(hexEntityRegex, in: s) { raw in
            guard let scalar = UInt32(raw, radix: 16), let unicode = Unicode.Scalar(scalar) else { return "" }
            return String(Character(unicode))
        }
        s = replaceGroup1(decimalEntityRegex, in: s) { raw in
            guard let value = UInt32(raw), let unicode = Unicode.Scalar(value) else { return "" }
            return String(Character(unicode))
        }
        // `&amp;` last, so a literal "&amp;lt;" decodes to "&lt;" rather than "<".
        return s.replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - Reset times

    /// The plan label that follows the "Cloud Usage" heading (Free / Pro / Max / Team), or `nil`. The
    /// badge is rendered in title case via CSS while the raw text is lowercase ("pro"), so capitalize the
    /// capture for a proper label.
    private static func planFromText(_ text: String) -> String? {
        group1Matches(of: planRegex, in: text).first?.capitalized
    }

    /// A `data-time` ISO-8601 value (e.g. `2026-05-16T14:55:00Z`) as a `Date`.
    private static func resetDate(_ raw: String?) -> Date? {
        guard let raw = raw?.nilIfEmpty else { return nil }
        return OpenUsageISO8601.date(from: raw)
    }

    /// Resolve a relative "Resets in N <unit>" phrase against `now` — the fallback when a section has no
    /// `data-time`. Mirrors the legacy plugin's unit table (minute/hour/day/week and their abbreviations).
    private static func relativeReset(in section: String, now: Date) -> Date? {
        let matches = relativeResetRegex.matches(in: section, range: NSRange(section.startIndex..., in: section))
        guard let match = matches.first,
              let amountRange = Range(match.range(at: 1), in: section),
              let unitRange = Range(match.range(at: 2), in: section),
              let amount = Double(section[amountRange])
        else { return nil }

        let factor: TimeInterval
        switch section[unitRange].lowercased() {
        case "second", "seconds": factor = 1
        case "minute", "minutes", "min", "m": factor = 60
        case "hour", "hours", "h": factor = 60 * 60
        case "day", "days", "d": factor = 24 * 60 * 60
        case "week", "weeks", "w": factor = 7 * 24 * 60 * 60
        default: return nil
        }
        return now.addingTimeInterval(amount * factor)
    }

    /// The slice of `text` from `start` (inclusive) to `end` (exclusive), case-insensitive — used to
    /// scope the relative-reset fallback to the right meter's section. Empty when `start` is absent.
    private static func sectionBetween(_ text: String, start: String, end: String) -> String {
        let lower = text.lowercased()
        guard let startRange = lower.range(of: start.lowercased()) else { return "" }
        let after = String(text[startRange.lowerBound...])
        guard let endRange = after.lowercased().range(of: end.lowercased()) else { return after }
        return String(after[..<endRange.lowerBound])
    }

    // MARK: - JSON helpers

    private static func nestedObject(_ root: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = root[key] as? [String: Any] { return value }
        }
        return nil
    }

    private static func firstNumber(_ object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = ProviderParse.number(object[key]) { return value }
        }
        return nil
    }

    private static func clampPercent(_ value: Double?) -> Double? {
        value.map(ProviderParse.clampPercent)
    }

    // MARK: - Regex

    private static let percentUsedRegex = makeRegex(#"(\d+(?:\.\d+)?)%\s*used"#)
    /// The meters' accessible labels — `aria-label="Session usage 0% used"`. Present in every meter state
    /// (a capped meter shows a status phrase in its visible text but keeps its percentage here).
    private static let sessionAriaRegex = makeRegex(#"aria-label="Session usage\s+(\d+(?:\.\d+)?)\s*%\s*used"#)
    private static let weeklyAriaRegex = makeRegex(#"aria-label="Weekly usage\s+(\d+(?:\.\d+)?)\s*%\s*used"#)
    private static let dataTimeRegex = makeRegex(#"data-time="([^"]+)""#)
    private static let planRegex = makeRegex(#"Cloud Usage\s+(Free|Pro|Max|Team)\b"#)
    private static let relativeResetRegex = makeRegex(
        #"Resets in\s+(?:less than\s+)?(\d+(?:\.\d+)?)\s*(second|seconds|minute|minutes|min|m|hour|hours|h|day|days|d|week|weeks|w)"#
    )
    private static let decimalEntityRegex = makeRegex(#"&#(\d+);"#)
    private static let hexEntityRegex = makeRegex(#"&#x([0-9a-fA-F]+);"#)

    /// Patterns are static literals ported from the legacy plugin; a failure here is a programmer error,
    /// so fail loudly (mirrors `LogRedaction.makeRegex`).
    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            fatalError("OllamaUsageMapper: invalid regex pattern: \(pattern)")
        }
        return regex
    }

    /// Every capture-group-1 match of `regex` in `input`, in order.
    private static func group1Matches(of regex: NSRegularExpression, in input: String) -> [String] {
        let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
        return matches.compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: input) else { return nil }
            return String(input[range])
        }
    }

    /// Replace every match of `regex`, passing capture group 1 to `transform`. Reverse order keeps
    /// earlier ranges valid as later ones are replaced (mirrors `LogRedaction.replaceGroup1`).
    private static func replaceGroup1(
        _ regex: NSRegularExpression,
        in input: String,
        transform: (String) -> String
    ) -> String {
        let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
        guard !matches.isEmpty else { return input }
        var result = input
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let groupRange = Range(match.range(at: 1), in: result),
                  let wholeRange = Range(match.range, in: result)
            else { continue }
            result.replaceSubrange(wholeRange, with: transform(String(result[groupRange])))
        }
        return result
    }
}

private extension Array {
    /// Safe index read: `nil` past the end instead of trapping.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
