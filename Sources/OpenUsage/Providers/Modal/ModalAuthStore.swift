import Foundation

struct ModalAuth: Hashable, Sendable {
    var sessionCookie: String
}

enum ModalAuthError: Error, LocalizedError, Equatable {
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
            return "No Modal session cookie. Set MODAL_SESSION_COOKIE or add it via Settings."
        case .invalidKey:
            return "Modal session expired. Update your session cookie."
        case .saveFailed:
            return "Couldn't save the Modal session cookie."
        case .deleteFailed:
            return "Couldn't remove the saved Modal session cookie."
        }
    }
}

/// Reads a [Modal](https://modal.com) web dashboard session cookie (`modal-session`) the user has
/// supplied. Modal's CLI stores its token in `~/.modal.toml`, but that is a gRPC credential for the
/// SDK — the usage/billing data lives behind the dashboard's cookie-authenticated REST API, which the
/// CLI credential cannot reach. So the cookie comes from an environment variable or a small config
/// file — the same pattern as OpenRouter, Z.ai, Ollama, and Qwen. A GUI app launched from Finder/Dock
/// doesn't inherit the interactive shell environment, so `ProcessEnvironmentReader` captures the login
/// shell's environment at launch (see `LoginShellEnvironment`); the config file remains the explicit path.
struct ModalAuthStore: Sendable {
    /// Config files checked in order; first readable key wins. JSON (`apiKey` / `api_key` / `key`) or a
    /// plain-text file containing only the cookie value.
    static let configPaths = [
        "~/.config/openusage/modal.json"
    ]
    /// Environment variables checked in order. `MODAL_SESSION_COOKIE` is the primary name;
    /// `MODAL_COOKIE` is accepted as a fallback (a full Cookie header from which the `modal-session`
    /// value is extracted).
    static let environmentNames = ["MODAL_SESSION_COOKIE", "MODAL_COOKIE"]
    /// The cookie that authenticates the Modal web dashboard's `/api/*` endpoints.
    static let sessionCookieName = "modal-session"

    private let store: UserAPIKeyStore

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        store = UserAPIKeyStore(
            configPaths: Self.configPaths,
            environmentNames: Self.environmentNames,
            files: files,
            environment: environment,
            makeError: { ModalAuthError($0) }
        )
    }

    /// Load the session cookie, extracting the `modal-session` value from a full Cookie header
    /// if needed.
    func loadSessionCookie() -> ModalAuth? {
        store.loadKey().flatMap { raw in
            Self.extractCookieValue(from: raw).map(ModalAuth.init(sessionCookie:))
        }
    }

    func currentAPIKey() -> String? {
        store.loadKey().flatMap { Self.extractCookieValue(from: $0) }
    }

    func keyStatus() -> APIKeyStatus { store.keyStatus() }
    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }

    /// Extract the `modal-session` value from a raw string. Accepts either the bare cookie value or a
    /// `Cookie:` header containing `modal-session=...` (with or without other cookies).
    static func extractCookieValue(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // Reject values that are unreasonably long (typical session cookies are < 1KB).
        guard text.count <= 4096 else { return nil }
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
                if name == sessionCookieName {
                    let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    // Validate extracted value: reasonable length and no control characters.
                    guard !value.isEmpty, value.count <= 4096 else { return nil }
                    guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
                    return value
                }
            }
        }
        // No matching cookie: a bare value (no semicolon) is the cookie itself; a multi-cookie header
        // without the session cookie is rejected.
        guard !header.contains(";") else { return nil }
        let bareValue = header.nilIfEmpty
        // Validate bare value with same checks.
        guard let value = bareValue, value.count <= 4096 else { return nil }
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }
}
