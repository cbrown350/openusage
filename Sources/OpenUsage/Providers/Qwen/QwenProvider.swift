import Foundation

@MainActor
final class QwenProvider: ProviderRuntime {
    let provider = Provider(
        id: "qwen",
        displayName: "Qwen",
        icon: .providerMark("qwen"),
        links: [
            ProviderLink(label: "Dashboard", url: QwenUsageClient.billingPageURL.absoluteString)
        ]
    )

    let authStore: QwenAuthStore
    let usageClient: QwenUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: QwenAuthStore = QwenAuthStore(),
        usageClient: QwenUsageClient = QwenUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "qwen.fiveHour", provider: provider, title: "5-Hour Window",
                     metricLabel: "5-Hour Window", isSessionWindow: true)
                .exportingLimit("fiveHour", unit: "percent"),
            .percent(id: "qwen.weekly", provider: provider, title: "Weekly",
                     metricLabel: "Weekly")
                .exportingLimit("weekly", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: a stored or environment-exported session ticket.
        await loadOffMainActor { [authStore] in authStore.loadSessionTicket() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadSessionTicket() }) else {
            return ProviderSnapshot.error(provider: provider, error: QwenAuthError.missingKey)
        }

        // Step 1: best-effort lift of the CSRF `SEC_TOKEN` from the billing page.
        //
        // The console migrated to a client-rendered SPA shell that no longer embeds `SEC_TOKEN` in the
        // server HTML, and the gateway no longer enforces the field (an empty or bogus `sec_token` still
        // passes CSRF and is authorized purely on the ticket cookie). So a missing token is NOT an
        // expired session — treating it as one made every refresh fail with "session expired" even
        // immediately after the user pasted a fresh ticket. Send whatever the page yields (empty when
        // absent) and let the gateway be the sole judge of the ticket.
        let page = try? await usageClient.fetchBillingPage(sessionTicket: auth.sessionTicket)
        if let page, let expired = Self.authFailureStatus(page.statusCode) {
            return ProviderSnapshot.error(provider: provider, error: expired)
        }
        let secToken = page
            .map { QwenUsageClient.extractSecToken(from: String(decoding: $0.body, as: UTF8.self)) ?? "" } ?? ""

        // Step 2: the usage windows are required; the subscription (plan tier) is best-effort.
        let usage = await load { try await usageClient.fetchUsage(sessionTicket: auth.sessionTicket, secToken: secToken) }
        let subscription = await loadOptional {
            try await usageClient.fetchSubscription(sessionTicket: auth.sessionTicket, secToken: secToken)
        }

        switch usage {
        case .success(let body):
            // The gateway answers 200 even for a dead ticket, flagging it only in the envelope. Classify
            // that as an expired session so the user is told to refresh the ticket rather than shown a
            // misleading parse error.
            guard !QwenUsageMapper.isNotLoggedIn(body) else {
                return ProviderSnapshot.error(provider: provider, error: QwenUsageError.sessionExpired)
            }
            do {
                let mapped = try QwenUsageMapper.map(usageBody: body, subscriptionBody: subscription)
                return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        case .authFailure(let error):
            return ProviderSnapshot.error(provider: provider, error: error)
        case .failed(let error):
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    // MARK: - Private

    /// Redirects and auth statuses mean the ticket didn't authenticate. `URLSession` normally follows
    /// redirects (so an expired ticket usually surfaces as a token-less login page above), but a
    /// non-followed 3xx/401/403 is classified here for robustness.
    private static func authFailureStatus(_ status: Int) -> QwenUsageError? {
        switch status {
        case 302, 303, 307, 308, 401, 403: return .sessionExpired
        default: return nil
        }
    }

    /// Run the required usage call and classify the outcome: the body on 2xx, an auth failure on
    /// 3xx/401/403, or a typed failure for any other non-2xx or transport error.
    private func load(_ call: () async throws -> HTTPResponse) async -> UsageResult {
        do {
            let response = try await call()
            if let failed = Self.authFailureStatus(response.statusCode) { return .authFailure(failed) }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.requestFailed(response.statusCode))
            }
            return .success(response.body)
        } catch {
            return .failed(.connectionFailed)
        }
    }

    /// Run the optional subscription call — never throws into the snapshot: a transport error, a
    /// non-2xx, or an auth failure all just mean "no plan name this refresh".
    private func loadOptional(_ call: () async throws -> HTTPResponse) async -> Data? {
        do {
            let response = try await call()
            guard (200..<300).contains(response.statusCode) else { return nil }
            return response.body
        } catch {
            return nil
        }
    }
}

extension QwenProvider: APIKeyManaging {
    var credentialKind: CredentialKind { .sessionKey(cookieName: QwenAuthStore.ticketCookieName) }
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}

private enum UsageResult {
    case success(Data)
    case authFailure(QwenUsageError)
    case failed(QwenUsageError)
}
