import Foundation

/// One Ollama account the user has added. Persisted in UserDefaults.
/// Identity key is the array index (stable once assigned), extensible to a hash
/// if a future discovery source provides natural identity.
struct OllamaAccountRecord: Codable, Equatable, Sendable, Identifiable {
    var id: Int

    /// The session cookie for this account's ollama.com login.
    var sessionCookie: String

    /// Name discovered from the settings page HTML, updated each refresh.
    var discoveredLabel: String?

    /// User-chosen name via Rename. Wins over discoveredLabel and the id fallback.
    var customLabel: String?

    /// When the user explicitly removes an account. Tombstoned accounts are
    /// never rendered and never resurrected by a page re-scrape.
    var removedTombstone: Bool = false

    /// The name shown before a rename: discovered label ("Account Name"),
    /// or the generic fallback ("Account 1", "Account 2").
    var derivedDisplayName: String {
        guard let label = discoveredLabel?.nilIfEmpty else {
            return "Account \(id + 1)"
        }
        return label
    }

    /// THE name resolver for Ollama accounts -- mirrors Claude's pattern.
    var resolvedDisplayName: String {
        customLabel?.nilIfEmpty ?? derivedDisplayName
    }
}
