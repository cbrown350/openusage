import Foundation

@MainActor
final class OllamaProvider: ProviderRuntime {
    let provider = Provider(
        id: "ollama",
        displayName: "Ollama",
        icon: .providerMark("ollama"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://ollama.com/settings")
        ]
    )

    let authStore: OllamaAuthStore
    let usageClient: OllamaUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: OllamaAuthStore = OllamaAuthStore(),
        usageClient: OllamaUsageClient = OllamaUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "ollama.session", provider: provider, title: "Session",
                     metricLabel: "Session", isSessionWindow: true)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "ollama.weekly", provider: provider, title: "Weekly",
                     metricLabel: "Weekly")
                .exportingLimit("weekly", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources `refresh()` reads: a stored/exported session cookie, or the env-only API key.
        await loadOffMainActor { [authStore] in
            authStore.loadSessionCookie() != nil || authStore.loadAPIKey() != nil
        }
    }

    func refresh() async -> ProviderSnapshot {
        // Primary: the session cookie → scrape the authenticated settings page. Fallback: an
        // `OLLAMA_API_KEY` → a future `GET /api/account/usage` (expected to 404 until Ollama ships it).
        if let session = await loadOffMainActor({ [authStore] in authStore.loadSessionCookie() }) {
            return await refreshFromSettings(sessionCookie: session.sessionCookie)
        }
        if let apiKey = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) {
            return await refreshFromAPI(apiKey: apiKey)
        }
        return ProviderSnapshot.error(provider: provider, error: OllamaAuthError.missingKey)
    }

    /// Scrape `ollama.com/settings` and map the Cloud Usage meters. A logged-out session follows the
    /// redirect to the login page (no "Cloud Usage" marker) → `sessionExpired`; a logged-in page whose
    /// shape changed (marker present but no parseable meters) → `invalidResponse`.
    private func refreshFromSettings(sessionCookie: String) async -> ProviderSnapshot {
        let response: HTTPResponse
        do {
            response = try await usageClient.fetchSettingsPage(sessionCookie: sessionCookie)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: OllamaUsageError.connectionFailed)
        }

        switch response.statusCode {
        case 302, 303, 307, 308, 401, 403:
            return ProviderSnapshot.error(provider: provider, error: OllamaUsageError.sessionExpired)
        case 200..<300:
            break
        default:
            return ProviderSnapshot.error(
                provider: provider, error: OllamaUsageError.requestFailed(response.statusCode)
            )
        }

        let html = String(decoding: response.body, as: UTF8.self)
        // A logged-in settings page carries the Cloud Usage heading/meters; their absence means the
        // cookie didn't authenticate (redirected to login), which reads as an expired session.
        guard OllamaUsageMapper.looksLikeUsagePage(html) else {
            return ProviderSnapshot.error(provider: provider, error: OllamaUsageError.sessionExpired)
        }
        guard let usage = OllamaUsageMapper.parseSettings(html: html, now: now()) else {
            return ProviderSnapshot.error(provider: provider, error: OllamaUsageError.invalidResponse)
        }
        return ProviderSnapshot.make(
            provider: provider, plan: usage.plan,
            lines: OllamaUsageMapper.lines(from: usage), refreshedAt: now()
        )
    }

    /// Future-proofed JSON path: `GET /api/account/usage` with an `OLLAMA_API_KEY`. Today this endpoint
    /// is expected to be absent (404); any non-2xx surfaces as a request failure rather than blank meters.
    private func refreshFromAPI(apiKey: String) async -> ProviderSnapshot {
        let response: HTTPResponse
        do {
            response = try await usageClient.fetchAPIUsage(apiKey: apiKey)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: OllamaUsageError.connectionFailed)
        }
        guard (200..<300).contains(response.statusCode) else {
            return ProviderSnapshot.error(
                provider: provider, error: OllamaUsageError.requestFailed(response.statusCode)
            )
        }
        guard let usage = OllamaUsageMapper.parseAPIUsage(response.body) else {
            return ProviderSnapshot.error(provider: provider, error: OllamaUsageError.invalidResponse)
        }
        return ProviderSnapshot.make(
            provider: provider, plan: usage.plan,
            lines: OllamaUsageMapper.lines(from: usage), refreshedAt: now()
        )
    }
}

extension OllamaProvider: APIKeyManaging {
    var credentialKind: CredentialKind { .sessionKey(cookieName: "__Secure-session") }
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}
