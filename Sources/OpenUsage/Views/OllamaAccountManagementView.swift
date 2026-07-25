import SwiftUI
import AppKit

/// Ollama account management: add, remove, rename, and update session cookies.
/// Shown in the Ollama card's Customize detail and accessible from the
/// card's context menu ("Manage Accounts…").
struct OllamaAccountManagementView: View {
    @Environment(OllamaAccountsStore.self) private var accounts

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header()

            if accounts.activeRecords.isEmpty {
                emptyState()
            } else {
                infoText()

                ForEach(accounts.activeRecords) { account in
                    OllamaAccountRow(record: account)
                }

                if !accounts.isAtCapacity {
                    AddOllamaAccountButton()
                } else {
                    Text("Maximum \(OllamaAccountsStore.maxAccounts) accounts reached")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
        }
    }

    private func header() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ollama Accounts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("Add multiple Ollama Cloud accounts to track usage across different logins")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func infoText() -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.caption2)
                .foregroundStyle(.blue)
            Text("Accounts below will appear as separate cards after restarting OpenUsage")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func emptyState() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No Ollama accounts configured")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Add an account to see usage data for your Ollama Cloud login")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            AddOllamaAccountButton()
        }
    }
}

/// Per-account row showing account name, status, and actions.
struct OllamaAccountRow: View {
    @Environment(OllamaAccountsStore.self) private var accounts
    let record: OllamaAccountRecord
    @State private var isShowingRenameDialog = false
    @State private var isShowingUpdateSheet = false
    @State private var renameText = ""

    private var accountOrdinal: Int {
        accounts.activeRecords.firstIndex(where: { $0.id == record.id }).map { $0 + 1 } ?? (record.id + 1)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Account indicator with its position-based number
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(accounts.displayName(accountID: record.id))
                        .font(.body)
                    Text("#\(accountOrdinal)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }

                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text("Session cookie configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button(action: {
                    renameText = record.customLabel ?? ""
                    isShowingRenameDialog = true
                }) {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Rename this account")
                .alert("Rename Account", isPresented: $isShowingRenameDialog) {
                    TextField("Account Name", text: $renameText)
                    Button("Cancel", role: .cancel) { }
                    Button("Rename") {
                        accounts.rename(cardID: OllamaAccountsStore.cardID(for: record.id), to: renameText)
                    }
                } message: {
                    Text("Enter a custom name for this Ollama account")
                }

                Button(action: { isShowingUpdateSheet = true }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Update session cookie")
                .sheet(isPresented: $isShowingUpdateSheet) {
                    UpdateOllamaAccountSheet(record: record)
                }

                Button(action: {
                    accounts.removeAccount(accountID: record.id)
                }) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Remove this account")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}

/// Button to add a new Ollama account.
struct AddOllamaAccountButton: View {
    @Environment(OllamaAccountsStore.self) private var accounts
    @State private var isShowingAddSheet = false

    var body: some View {
        Button(action: {
            isShowingAddSheet = true
        }) {
            Label("Add Ollama Account", systemImage: "plus.circle.fill")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .sheet(isPresented: $isShowingAddSheet) {
            AddOllamaAccountSheet(isPresented: $isShowingAddSheet)
                .environment(accounts)
        }
    }
}

/// Sheet for adding a new Ollama account with session cookie.
struct AddOllamaAccountSheet: View {
    @Environment(OllamaAccountsStore.self) private var accounts
    @Binding var isPresented: Bool
    @State private var sessionCookie: String = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showSuccessMessage = false
    @State private var createdAccountID: Int?

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Ollama Account")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Paste your __Secure-session cookie value from ollama.com")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("You can find this in your browser's developer tools → Application → Cookies")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            TextField("Session Cookie", text: $sessionCookie, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())

            if let error = errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if showSuccessMessage, let accountID = createdAccountID {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Account \(accountID + 1) added successfully!")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text("⚠️ Restart required to see it in the menu bar")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if showSuccessMessage {
                    Button("Restart Now") {
                        restartApp()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Add Account") {
                        addAccount()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sessionCookie.isEmpty || isProcessing)
                }
            }

            Spacer()
        }
        .padding()
    }

    private func addAccount() {
        isProcessing = true
        errorMessage = nil

        // Basic validation: check for reasonable cookie format
        guard validateCookieFormat(sessionCookie) else {
            errorMessage = "Invalid session cookie format"
            isProcessing = false
            return
        }

        // CRITICAL: Handle the legacy key properly
        // If there's a legacy key that's different from what we're adding, we need to handle it
        let legacyStore = OllamaAuthStore()
        let hasLegacyKey = legacyStore.loadSessionCookie() != nil
        let isLegacyKeyDifferent = hasLegacyKey && legacyStore.loadSessionCookie()?.sessionCookie != sessionCookie

        // If we have a legacy key that's different, we need to add BOTH accounts
        // The legacy key goes first, then the new key
        if isLegacyKeyDifferent {
            AppLog.info(.config, "AddOllamaAccountSheet: Adding legacy key first, then new key")

            // Add the legacy key as the first account (if not already present)
            let legacyAuth = legacyStore.loadSessionCookie()
            if let legacy = legacyAuth, !accounts.activeRecords.contains(where: { $0.sessionCookie == legacy.sessionCookie }) {
                let migratedRecord = accounts.addAccount(sessionCookie: legacy.sessionCookie)
                AppLog.info(.config, "AddOllamaAccountSheet: Legacy key added as account \(migratedRecord?.id ?? -1)")
            }
        }

        if let record = accounts.addAccount(sessionCookie: sessionCookie) {
            // Show success message with account details
            createdAccountID = record.id
            showSuccessMessage = true

            // IMPORTANT: After adding accounts, we need to rebuild the providers
            // For now, we require a restart, but we should make this dynamic in the future
            AppLog.info(.config, "AddOllamaAccountSheet: Account \(record.id) added - restart required to see in menu bar")
        } else {
            errorMessage = "Maximum accounts reached"
        }

        isProcessing = false
    }

    private func restartApp() {
        // Close the sheet first
        isPresented = false

        // Small delay to allow sheet to dismiss, then restart
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let bundleURL = Bundle.main.bundleURL
            // Try to open the app bundle, then terminate the current instance
            NSWorkspace.shared.open(bundleURL)
            NSApp.terminate(nil)
        }
    }

    private func validateCookieFormat(_ cookie: String) -> Bool {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        // Basic sanity checks: not empty, reasonable length, no control characters
        guard !trimmed.isEmpty else { return false }
        guard trimmed.count <= 4096 else { return false }
        guard !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        return true
    }
}

/// Sheet for updating an existing Ollama account's session cookie.
struct UpdateOllamaAccountSheet: View {
    @Environment(OllamaAccountsStore.self) private var accounts
    let record: OllamaAccountRecord
    @Environment(\.dismiss) private var dismiss
    @State private var sessionCookie: String = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Update Session Cookie")
                .font(.headline)

            Text("Update the __Secure-session cookie for \(accounts.displayName(accountID: record.id))")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Session Cookie", text: $sessionCookie, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Update") {
                    updateCookie()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sessionCookie.isEmpty || isProcessing)
            }

            Spacer()
        }
        .padding()
        .onAppear {
            sessionCookie = record.sessionCookie
        }
    }

    private func updateCookie() {
        isProcessing = true
        errorMessage = nil

        // Basic validation: check for reasonable cookie format
        guard validateCookieFormat(sessionCookie) else {
            errorMessage = "Invalid session cookie format"
            isProcessing = false
            return
        }

        accounts.updateSessionCookie(accountID: record.id, cookie: sessionCookie)
        AppLog.info(.config, "Updated session cookie for Ollama account: \(record.id)")
        dismiss()

        isProcessing = false
    }

    private func validateCookieFormat(_ cookie: String) -> Bool {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        // Basic sanity checks: not empty, reasonable length, no control characters
        guard !trimmed.isEmpty else { return false }
        guard trimmed.count <= 4096 else { return false }
        guard !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        return true
    }
}
