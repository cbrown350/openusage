import Foundation

/// The installed provider set and its canonical order. Both the menu-bar app and one-shot CLI build
/// their runtimes here so credentials, refresh behavior, pricing, and normalization can never drift.
@MainActor
enum ProviderCatalog {
    /// `claudeCards` carries the extra Claude account cards found by the launch account pass
    /// (`ProviderAccountAssembly`). Each becomes an ordinary runtime inserted right after the default
    /// Claude card, with credentials and usage logs pinned to exactly its own config dir. The empty
    /// default keeps the historical single-card set for focused tests and callers that intentionally
    /// skip the account pass.
    ///
    /// `ollamaCards` carries the GUI-managed Ollama account cards from `OllamaAccountAssembly`.
    /// Each becomes an independent runtime with its own session cookie and account name discovery.
    static func make(
        defaults: UserDefaults = .standard,
        claudeCards: [ClaudeAccountCard] = [],
        defaultClaudeExtraLogRoots: [URL] = [],
        ollamaCards: [OllamaAccountAssembly.OllamaAccountCard] = []
    ) -> [ProviderRuntime] {
        // Default provider order (see AGENTS.md "## Providers"): the three established providers first,
        // then every other provider alphabetically by display name. Account cards slot in right after
        // their family's default card.
        //
        // Every baked `Provider.displayName` here is the DERIVED default — renames live only in the
        // account registry and are resolved at render time (`ProviderAccountRecord.resolvedDisplayName`),
        // so a baked name can never be a stale copy of one.
        var runtimes: [ProviderRuntime] = []
        runtimes.append(ClaudeProvider(
            // Once extra Claude cards exist, an unpinned Desktop fallback could borrow a login that
            // belongs to one of them — fetching that account's usage onto the default card. Desktop
            // returns as its own properly-pinned source kind in Phase 3.
            authStore: ClaudeAuthStore(allowsDesktopFallback: claudeCards.isEmpty),
            logUsageScanner: ClaudeLogUsageScanner(additionalRoots: defaultClaudeExtraLogRoots)
        ))
        for card in claudeCards {
            runtimes.append(claudeAccountRuntime(card: card))
        }
        runtimes += [
            CodexProvider(),
            CursorProvider(),
            AntigravityProvider(),
            CopilotProvider(defaults: defaults),
            DevinProvider(),
            GrokProvider(),
        ]

        runtimes.append(ModalProvider())

        // Ollama multi-account setup
        AppLog.info(.config, "ProviderCatalog: building Ollama providers (\(ollamaCards.count) cards)")
        if ollamaCards.isEmpty {
            // No active account cards: use the default single-account provider, which reads the
            // baseline credential (ollama.json / env vars). Ollama always stays present as a provider
            // — deleting every multi-account card removes those cards but never the provider itself;
            // the deleted cards stay gone because migration never re-adds a tombstoned cookie.
            AppLog.info(.config, "ProviderCatalog: no active Ollama accounts, using default provider")
            runtimes.append(OllamaProvider())
        } else {
            // Has accounts: use the first account as the default, then add the rest
            AppLog.info(.config, "ProviderCatalog: creating \(ollamaCards.count) Ollama provider(s)")
            for (index, card) in ollamaCards.enumerated() {
                if index == 0 {
                    // First account becomes the default "ollama" card
                    AppLog.info(.config, "ProviderCatalog: creating 'ollama' (default) from account \(card.accountID): '\(card.displayName)'")
                    runtimes.append(OllamaProvider(
                        provider: OllamaProvider.makeProvider(id: "ollama", displayName: card.displayName),
                        authStore: OllamaAuthStore(accountID: card.accountID, sessionCookie: card.sessionCookie)
                    ))
                } else {
                    // Additional accounts become "ollama@N" cards
                    AppLog.info(.config, "ProviderCatalog: creating '\(card.id)' from account \(card.accountID): '\(card.displayName)'")
                    runtimes.append(ollamaAccountRuntime(card: card))
                }
            }
        }

        runtimes += [
            OpenCodeProvider(),
            OpenRouterProvider(),
            QwenProvider(),
            ZAIProvider()
        ]

        AppLog.info(.config, "ProviderCatalog: total providers created: \(runtimes.count)")
        return runtimes
    }

    /// An extra Claude account card: same provider machinery, credentials and logs pinned to one
    /// login. The scanner's parse cache is partitioned per card so distinct homes never share
    /// records.
    private static func claudeAccountRuntime(card: ClaudeAccountCard) -> ClaudeProvider {
        ClaudeProvider(
            provider: ClaudeProvider.makeProvider(id: card.id, displayName: card.displayName),
            authStore: ClaudeAuthStore(
                scope: .configDir(path: card.configDirPath, keychainLiteral: card.keychainLiteral)
            ),
            logUsageScanner: ClaudeLogUsageScanner(
                cacheIdentityOverride: "claude-account:\(card.id)",
                rootsOverride: [URL(fileURLWithPath: card.configDirPath)] + card.extraLogRoots
            )
        )
    }

    /// An extra Ollama account card: same provider machinery with its own session cookie and
    /// account name discovery callback.
    private static func ollamaAccountRuntime(card: OllamaAccountAssembly.OllamaAccountCard) -> OllamaProvider {
        let provider = OllamaProvider(
            provider: OllamaProvider.makeProvider(id: card.id, displayName: card.displayName),
            authStore: OllamaAuthStore(accountID: card.accountID, sessionCookie: card.sessionCookie)
        )
        return provider
    }
}
