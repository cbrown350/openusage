import Foundation

struct QwenAuth: Hashable, Sendable {
    var sessionTicket: String
}

enum QwenAuthError: Error, LocalizedError, Equatable {
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
            return "No Qwen session ticket. Set QWEN_SESSION_COOKIE or add it via Settings."
        case .invalidKey:
            return "Qwen session expired. Update your session ticket."
        case .saveFailed:
            return "Couldn't save the Qwen session ticket."
        case .deleteFailed:
            return "Couldn't remove the saved Qwen session ticket."
        }
    }
}

/// Reads a [Qwen Cloud](https://home.qwencloud.com) SSO session ticket (`login_qwencloud_ticket`) the
/// user has supplied. Qwen's billing console has no companion CLI/app that stashes a credential in a
/// known spot, so the ticket comes from an environment variable or a small config file — the same
/// pattern as OpenRouter, Z.ai, and Ollama. A GUI app launched from Finder/Dock doesn't inherit the
/// interactive shell environment, so `ProcessEnvironmentReader` captures the login shell's environment
/// at launch (see `LoginShellEnvironment`); the config file remains the explicit path.
struct QwenAuthStore: Sendable {
    /// Config files checked in order; first readable key wins. JSON (`apiKey` / `api_key` / `key`) or a
    /// plain-text file containing only the ticket value.
    static let configPaths = [
        "~/.config/openusage/qwen.json"
    ]
    /// Environment variables checked in order. `QWEN_SESSION_COOKIE` is the primary name; `QWEN_COOKIE`
    /// is accepted as a fallback (a full Cookie header from which the `login_qwencloud_ticket` value is
    /// extracted).
    static let environmentNames = ["QWEN_SESSION_COOKIE", "QWEN_COOKIE"]
    /// The SSO cookie that authenticates the Qwen Cloud console (standard Alibaba `login_*_ticket`).
    static let ticketCookieName = "login_qwencloud_ticket"

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
            makeError: { QwenAuthError($0) }
        )
    }

    /// Load the session ticket, extracting the `login_qwencloud_ticket` value from a full Cookie header
    /// if needed.
    func loadSessionTicket() -> QwenAuth? {
        store.loadKey().flatMap { raw in
            Self.extractTicketValue(from: raw).map(QwenAuth.init(sessionTicket:))
        }
    }

    func currentAPIKey() -> String? {
        store.loadKey().flatMap { Self.extractTicketValue(from: $0) }
    }

    func keyStatus() -> APIKeyStatus { store.keyStatus() }
    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }

    /// Extract the `login_qwencloud_ticket` value from a raw string. Accepts either the bare ticket
    /// value or a `Cookie:` header containing `login_qwencloud_ticket=...` (with or without other cookies).
    static func extractTicketValue(from raw: String) -> String? {
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
                if name == ticketCookieName {
                    let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    return value.isEmpty ? nil : value
                }
            }
        }
        // No matching cookie: a bare value (no semicolon) is the ticket itself; a multi-cookie header
        // without the ticket is rejected.
        return header.contains(";") ? nil : header.nilIfEmpty
    }
}
