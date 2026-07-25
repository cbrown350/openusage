import Foundation

/// Reads persisted Ollama accounts and produces the per-card build plan
/// for ProviderCatalog. Mirrors Claude's ProviderAccountAssembly pattern
/// but reads from the GUI-managed store instead of filesystem discovery.
@MainActor
struct OllamaAccountAssembly {
    /// Card id -> the session cookie for that account (for the snapshot cache stamp).
    let sessionCookiesByCard: [String: String]
    /// Extra Ollama account cards to build, in stable id order.
    var accountCards: [OllamaAccountCard] = []

    struct OllamaAccountCard: Equatable, Sendable {
        var id: String          // "ollama@N"
        var displayName: String  // derived default, never a rename
        var accountID: Int
        var sessionCookie: String
    }

    static func make(accountsStore: OllamaAccountsStore) -> OllamaAccountAssembly {
        var cookies: [String: String] = [:]
        var cards: [OllamaAccountCard] = []

        AppLog.info(.config, "OllamaAccountAssembly: building from \(accountsStore.activeRecords.count) active records")

        for record in accountsStore.activeRecords {
            let cardID = OllamaAccountsStore.cardID(for: record.id)
            let displayName = accountsStore.displayName(accountID: record.id)
            cookies[cardID] = record.sessionCookie
            cards.append(OllamaAccountCard(
                id: cardID,
                displayName: displayName,
                accountID: record.id,
                sessionCookie: record.sessionCookie
            ))
            AppLog.info(.config, "OllamaAccountAssembly: created card '\(cardID)' for account \(record.id): '\(displayName)'")
        }

        AppLog.info(.config, "OllamaAccountAssembly: built \(cards.count) cards")

        return OllamaAccountAssembly(
            sessionCookiesByCard: cookies,
            accountCards: cards
        )
    }
}
