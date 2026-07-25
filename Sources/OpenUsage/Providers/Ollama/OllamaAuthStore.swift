import Foundation

struct OllamaAuth: Hashable, Sendable {
    var sessionCookie: String
}

enum OllamaAuthError: Error, LocalizedError, Equatable {
    case missingKey
    case invalidKey
    case saveFailed
    case deleteFailed

    init(_ failure: UserAPIKeyStore.Failure) {
        switch failure {
        case .missingKey: self = .missingKey
        case .saveFailed: self = .saveFailed
        case .deleteFailed: self = .deleteFailed
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No Ollama session cookie. Set OLLAMA_SESSION_COOKIE or add it via Settings."
        case .invalidKey:
            return "Ollama session expired. Update your session cookie."
        case .saveFailed:
            return "Couldn't save the Ollama session cookie."
        case .deleteFailed:
            return "Couldn't remove the saved Ollama session cookie."
        }
    }
}

/// Reads an Ollama Cloud session cookie (`__Secure-session`) the user has supplied. Ollama has no
/// companion CLI/app that stashes a cloud-session credential in a known spot, so the cookie comes
/// from an environment variable or a small config file — the same pattern as OpenRouter and Z.ai.
/// A GUI app launched from Finder/Dock doesn't inherit the interactive shell environment, so
/// `ProcessEnvironmentReader` captures the login shell's environment at launch (see
/// `LoginShellEnvironment`) — meaning an env var exported in a shell profile is honored even in a
/// packaged build; the config file remains the explicit path.
struct OllamaAuthStore: Sendable {
    /// Config files checked in order; first readable key wins. JSON (`apiKey` / `api_key` / `key`) or a
    /// plain-text file containing only the cookie value.
    static let configPaths = [
        "~/.config/openusage/ollama.json"
    ]
    /// Environment variables checked in order. `OLLAMA_SESSION_COOKIE` is the primary name;
    /// `OLLAMA_COOKIE` is accepted as a fallback (a full Cookie header value from which the
    /// `__Secure-session` value is extracted).
    static let environmentNames = ["OLLAMA_SESSION_COOKIE", "OLLAMA_COOKIE"]
    /// Environment-only fallback credential for a future `GET /api/account/usage`: an Ollama API key.
    /// Not managed through the Settings card (that edits the session cookie); read straight from the
    /// environment so a user who exports `OLLAMA_API_KEY` gets the API path without a config file.
    static let apiKeyEnvironmentName = "OLLAMA_API_KEY"

    private let store: UserAPIKeyStore
    private let environment: EnvironmentReading

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.environment = environment
        store = UserAPIKeyStore(
            configPaths: Self.configPaths,
            environmentNames: Self.environmentNames,
            files: files,
            environment: environment,
            makeError: { OllamaAuthError($0) }
        )
    }

    /// Load the session cookie, extracting the `__Secure-session` value from a full Cookie header
    /// if needed.
    func loadSessionCookie() -> OllamaAuth? {
        store.loadKey().flatMap { raw in
            Self.extractSessionValue(from: raw).map(OllamaAuth.init(sessionCookie:))
        }
    }

    func currentAPIKey() -> String? {
        store.loadKey().flatMap { Self.extractSessionValue(from: $0) }
    }

    /// The env-only `OLLAMA_API_KEY` fallback (a Bearer token for a future `/api/account/usage`), or
    /// `nil`. Distinct from the GUI-managed session cookie above.
    func loadAPIKey() -> String? {
        environment.value(for: Self.apiKeyEnvironmentName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    func keyStatus() -> APIKeyStatus { store.keyStatus() }
    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }

    /// Extract the `__Secure-session` value from a raw string. Accepts either the bare cookie value
    /// or a `Cookie:` header containing `__Secure-session=...` (with or without other cookies).
    static func extractSessionValue(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // Strip a leading "Cookie:" prefix if present.
        let header = text.replacingOccurrences(
            of: "^Cookie:\\s*",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Try to parse as a cookie header first: split on ";", return the value whose name matches.
        // A single "name=value" with no semicolon is handled here too (one split element).
        for part in header.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if let eq = trimmed.firstIndex(of: "=") {
                let name = trimmed[trimmed.startIndex..<eq].trimmingCharacters(in: .whitespaces)
                if name == "__Secure-session" {
                    let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    return value.isEmpty ? nil : value
                }
            }
        }
        // No matching cookie: a bare value (no semicolon) is the cookie itself; a multi-cookie header
        // without the session cookie is rejected.
        return header.contains(";") ? nil : header.nilIfEmpty
    }
}
