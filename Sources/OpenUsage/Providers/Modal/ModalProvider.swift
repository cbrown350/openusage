import Foundation

@MainActor
final class ModalProvider: ProviderRuntime {
    let provider = Provider(
        id: "modal",
        displayName: "Modal",
        icon: .providerMark("modal"),
        links: [
            ProviderLink(label: "Usage", url: ModalUsageClient.usagePageURL.absoluteString)
        ]
    )

    let authStore: ModalAuthStore
    let usageClient: ModalUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: ModalAuthStore = ModalAuthStore(),
        usageClient: ModalUsageClient = ModalUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .boundedDollars(id: "modal.spend", provider: provider, title: "Spend",
                            metricLabel: "Spend", limit: 0, limitNoun: "limit")
                .exportingLimit("spend", unit: "usd"),
            .dollarBalance(id: "modal.credits", provider: provider, title: "Credits",
                           metricLabel: "Credits", valueWord: "left")
                .exportingLimit("credits", kind: .balance, unit: "usd", source: .value(kind: .dollars))
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: a stored or environment-exported `modal-session` cookie.
        await loadOffMainActor { [authStore] in authStore.loadSessionCookie() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadSessionCookie() }) else {
            return ProviderSnapshot.error(provider: provider, error: ModalAuthError.missingKey)
        }
        let cookie = auth.sessionCookie

        // The billing object is required; the billing cycles (reset date) are best-effort.
        switch await loadWorkspaces(sessionCookie: cookie) {
        case .success(let workspacesBody):
            // Route the cycles call by the workspace username the object carries.
            let username = ModalUsageMapper.workspaceUsername(from: workspacesBody)
            let cyclesBody: Data?
            if let username {
                cyclesBody = await loadBillingCycles(workspace: username, sessionCookie: cookie)
            } else {
                cyclesBody = nil
            }
            do {
                let mapped = try ModalUsageMapper.map(workspacesBody: workspacesBody, cyclesBody: cyclesBody)
                return ProviderSnapshot.make(
                    provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now()
                )
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        case .failed(let error):
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    // MARK: - Private

    /// Redirects and auth statuses mean the cookie didn't authenticate; the dashboard answers an
    /// unauthenticated API call with a clean JSON `401`.
    private static func authFailureStatus(_ status: Int) -> ModalUsageError? {
        switch status {
        case 302, 303, 307, 308, 401, 403: return .sessionExpired
        default: return nil
        }
    }

    private func loadWorkspaces(sessionCookie: String) async -> WorkspacesResult {
        do {
            let response = try await usageClient.fetchWorkspaces(sessionCookie: sessionCookie)
            // A redirect/auth status means the cookie didn't authenticate; the dashboard answers an
            // unauthenticated API call with a clean JSON `401`.
            if let failed = Self.authFailureStatus(response.statusCode) { return .failed(failed) }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.requestFailed(response.statusCode))
            }
            return .success(response.body)
        } catch {
            return .failed(.connectionFailed)
        }
    }

    /// The cycles call never throws into the snapshot: a transport error, a non-2xx, or an auth
    /// failure all just mean "no reset date this refresh".
    private func loadBillingCycles(workspace: String, sessionCookie: String) async -> Data? {
        do {
            let response = try await usageClient.fetchBillingCycles(workspace: workspace, sessionCookie: sessionCookie)
            guard (200..<300).contains(response.statusCode) else { return nil }
            return response.body
        } catch {
            return nil
        }
    }
}

extension ModalProvider: APIKeyManaging {
    var credentialKind: CredentialKind { .sessionKey(cookieName: ModalAuthStore.sessionCookieName) }
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}

private enum WorkspacesResult {
    case success(Data)
    case failed(ModalUsageError)
}
