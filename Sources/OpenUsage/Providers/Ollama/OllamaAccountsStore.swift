import Foundation
import Observation

/// Persisted account registry for GUI-managed Ollama accounts.
/// Unlike ProviderAccountsStore (which reconciles from filesystem discovery),
/// this store is the authoritative source -- accounts exist because the user
/// added them through the UI.
@MainActor
@Observable
final class OllamaAccountsStore {
    static let storageKey = "openusage.ollamaAccounts.v1"
    static let maxAccounts = 5

    private let defaults: UserDefaults
    private let shouldMigrateLegacyAccount: Bool
    private(set) var records: [OllamaAccountRecord]

    init(defaults: UserDefaults = .standard, shouldMigrateLegacyAccount: Bool = true) {
        self.defaults = defaults
        self.shouldMigrateLegacyAccount = shouldMigrateLegacyAccount
        if let data = defaults.data(forKey: Self.storageKey), !data.isEmpty {
            do {
                let decoder = JSONDecoder()
                self.records = try decoder.decode([OllamaAccountRecord].self, from: data)
                AppLog.info(.config, "✅ Successfully loaded \(self.records.count) Ollama accounts from UserDefaults")
                for record in self.records {
                    AppLog.debug(.config, "  - Account \(record.id): '\(record.resolvedDisplayName)' (removed: \(record.removedTombstone))")
                }
                // Heal stores corrupted by the legacy duplicate-ID bug (delete-then-add reused an ID,
                // leaving a tombstoned and an active record with the same `id`).
                repairDuplicateIDsIfNeeded()
            } catch {
                AppLog.error(.config, "❌ Failed to decode Ollama accounts: \(error.localizedDescription)")
                self.records = []
            }
        } else {
            self.records = []
            if defaults.data(forKey: Self.storageKey) != nil {
                AppLog.error(.config, "❌ Found data in UserDefaults but it's empty - treating as no accounts")
            } else {
                AppLog.info(.config, "No Ollama accounts found in UserDefaults (no data key)")
            }
        }

        // Migration: always check for legacy cookie and migrate if it doesn't exist in accounts
        // This handles the case where user adds a legacy key first, then uses multi-account UI
        if shouldMigrateLegacyAccount {
            migrateLegacyAccount()
        }

        AppLog.info(.config, "OllamaAccountsStore initialized with \(activeRecords.count) active accounts")
    }

    // MARK: - Queries

    /// Active (non-tombstoned) records in id order.
    var activeRecords: [OllamaAccountRecord] {
        records.filter { !$0.removedTombstone }.sorted { $0.id < $1.id }
    }

    /// Resolved display name for a card id ("ollama@N"), or nil.
    func resolvedDisplayName(cardID: String) -> String? {
        guard let accountID = Self.accountID(from: cardID) else { return nil }
        guard records.contains(where: { $0.id == accountID && !$0.removedTombstone }) else { return nil }
        return displayName(accountID: accountID)
    }

    /// The name shown for an account: custom label → discovered label → "Account N", where N is the
    /// 1-based position among *active* accounts. Basing the fallback on position (not the raw record
    /// id) means deleting an account doesn't leave a gap — the remaining accounts stay "Account 1",
    /// "Account 2", … even though their stable ids (used for card identity) keep their original numbers.
    func displayName(accountID: Int) -> String {
        guard let record = records.first(where: { $0.id == accountID && !$0.removedTombstone }) else {
            return "Account \(accountID + 1)"
        }
        if let custom = record.customLabel?.nilIfEmpty { return custom }
        if let discovered = record.discoveredLabel?.nilIfEmpty { return discovered }
        let ordinal = activeRecords.firstIndex(where: { $0.id == accountID }).map { $0 + 1 } ?? (accountID + 1)
        return "Account \(ordinal)"
    }

    /// Whether the store is at capacity.
    var isAtCapacity: Bool {
        activeRecords.count >= Self.maxAccounts
    }

    // MARK: - Mutations (all persist immediately)

    /// Add a new account with the given session cookie. Returns the created record, or nil if at capacity.
    @discardableResult
    func addAccount(sessionCookie: String) -> OllamaAccountRecord? {
        AppLog.info(.config, "addAccount() called - activeRecords: \(activeRecords.count), isAtCapacity: \(isAtCapacity)")

        guard !isAtCapacity else {
            AppLog.error(.config, "Cannot add account - at capacity")
            return nil
        }

        // Find the highest ID across ALL records (including tombstoned) and use the next sequential
        // ID. Using only active records here reused a just-deleted account's ID, creating two records
        // with the same `id` — which made deletion appear to do nothing (the active twin survived).
        let maxID = records.map { $0.id }.max()
        let nextID = maxID.map { $0 + 1 } ?? 0

        AppLog.info(.config, "Creating Ollama account with ID: \(nextID) (max was: \(String(describing: maxID)))")

        let record = OllamaAccountRecord(
            id: nextID,
            sessionCookie: sessionCookie,
            discoveredLabel: nil,
            customLabel: nil,
            removedTombstone: false
        )
        records.append(record)

        AppLog.info(.config, "Persisting \(records.count) Ollama accounts")
        persist()

        AppLog.info(.config, "Created account: id=\(record.id), name='\(record.derivedDisplayName)'")

        // Verify persistence
        if let data = defaults.data(forKey: Self.storageKey) {
            AppLog.info(.config, "Verification: \(data.count) bytes in UserDefaults")
        } else {
            AppLog.error(.config, "ERROR: No data in UserDefaults after persist!")
        }

        return record
    }

    /// Update the session cookie for an existing account.
    func updateSessionCookie(accountID: Int, cookie: String) {
        guard let index = records.firstIndex(where: { $0.id == accountID }) else { return }
        records[index] = OllamaAccountRecord(
            id: records[index].id,
            sessionCookie: cookie,
            discoveredLabel: records[index].discoveredLabel,
            customLabel: records[index].customLabel,
            removedTombstone: records[index].removedTombstone
        )
        persist()
    }

    /// Rename an account by cardID.
    func rename(cardID: String, to name: String?) {
        guard let accountID = Self.accountID(from: cardID),
              let index = records.firstIndex(where: { $0.id == accountID }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        records[index] = OllamaAccountRecord(
            id: records[index].id,
            sessionCookie: records[index].sessionCookie,
            discoveredLabel: records[index].discoveredLabel,
            customLabel: trimmed?.nilIfEmpty,
            removedTombstone: records[index].removedTombstone
        )
        persist()
    }

    /// Remove an account by marking it as tombstoned. Targets the *active* record for the ID so a
    /// stray tombstoned twin (from the legacy duplicate-ID bug) can't shadow the deletion.
    func removeAccount(accountID: Int) {
        guard let index = records.firstIndex(where: { $0.id == accountID && !$0.removedTombstone }) else { return }
        // Create a new record with tombstone set to ensure SwiftUI @Observable tracks the change
        records[index] = OllamaAccountRecord(
            id: records[index].id,
            sessionCookie: records[index].sessionCookie,
            discoveredLabel: records[index].discoveredLabel,
            customLabel: records[index].customLabel,
            removedTombstone: true
        )
        persist()
    }

    /// Refresh-time update: store the discovered name from the settings page.
    func updateDiscoveredLabel(accountID: Int, label: String?) {
        guard let index = records.firstIndex(where: { $0.id == accountID }) else { return }
        // Don't overwrite a custom label
        guard records[index].customLabel == nil || records[index].customLabel?.isEmpty == true else { return }
        // Replace the whole record so SwiftUI's @Observable tracking fires.
        records[index] = OllamaAccountRecord(
            id: records[index].id,
            sessionCookie: records[index].sessionCookie,
            discoveredLabel: label,
            customLabel: records[index].customLabel,
            removedTombstone: records[index].removedTombstone
        )
        persist()
    }

    // MARK: - ID helpers

    /// Card id for an Ollama account: "ollama@N" where N is the record id.
    /// This is NOT a hash (unlike Claude) because there is no natural identity
    /// key to hash; the index is the stable identity.
    static func cardID(for accountID: Int) -> String {
        "ollama@\(accountID)"
    }

    /// Parse an account id from a card id. Returns nil for the bare "ollama".
    static func accountID(from cardID: String) -> Int? {
        guard cardID.hasPrefix("ollama@") else { return nil }
        let suffix = cardID.dropFirst(7)
        return Int(suffix)
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(records)
            defaults.set(data, forKey: Self.storageKey)
            defaults.synchronize()
            AppLog.info(.config, "Persisted \(records.count) Ollama accounts to UserDefaults")
        } catch {
            AppLog.error(.config, "Failed to persist Ollama accounts: \(error.localizedDescription)")
        }
    }

    /// Collapse duplicate `id`s left behind by the legacy delete-then-add bug. For each ID with more
    /// than one record, keep a single record — preferring an active (non-tombstoned) one so the account
    /// the user can still see is the survivor. Persists only when something actually changed.
    private func repairDuplicateIDsIfNeeded() {
        var seen: Set<Int> = []
        var repaired: [OllamaAccountRecord] = []
        // First pass keeps active records; a tombstoned twin is dropped if an active one exists.
        for record in records where !record.removedTombstone {
            if seen.insert(record.id).inserted {
                repaired.append(record)
            }
        }
        // Second pass keeps a lone tombstoned record only if no active record claimed that ID.
        for record in records where record.removedTombstone {
            if seen.insert(record.id).inserted {
                repaired.append(record)
            }
        }
        guard repaired.count != records.count else { return }
        AppLog.warn(.config, "Repaired Ollama accounts: collapsed \(records.count) records to \(repaired.count) (duplicate IDs)")
        records = repaired.sorted { $0.id < $1.id }
        persist()
    }

    /// Debug method to check current state
    func debugState() {
        AppLog.debug(.config, "OllamaAccountsStore state:")
        AppLog.debug(.config, "  - Total records: \(records.count)")
        AppLog.debug(.config, "  - Active records: \(activeRecords.count)")
        for record in records {
            AppLog.debug(.config, "  - Record id=\(record.id), removed=\(record.removedTombstone), name='\(record.resolvedDisplayName)'")
        }
    }

    /// Migration: read the legacy single-account cookie from `ollama.json` / env vars, move it into
    /// the multi-account store, then clear the file-backed copy. `ollama.json` is OpenUsage's own
    /// config (not user data), and the multi-account store is the source of truth — so once a legacy
    /// cookie is represented in the store, the redundant file copy is removed. This is what makes GUI
    /// edits authoritative: deleting an account in the UI can't be resurrected by a stale file copy,
    /// and a user hand-editing `ollama.json` seeds a fresh account on next launch.
    private func migrateLegacyAccount() {
        AppLog.info(.config, "OllamaAccountsStore: checking for legacy cookie to migrate")

        // Read from the legacy OllamaAuthStore pattern
        let legacyStore = OllamaAuthStore()

        // Try to load a session cookie from legacy sources (config file or env vars)
        guard let legacyAuth = legacyStore.loadSessionCookie() else {
            AppLog.info(.config, "OllamaAccountsStore: no legacy cookie found, skipping migration")
            return
        }

        // Move the credential into the store (no-op if already present, active or tombstoned).
        migrateCookieIfNeeded(legacyAuth.sessionCookie)

        // Consume the file-backed copy so the store is the single source of truth. `deleteAPIKey`
        // removes the config file and is a no-op when the cookie came from an environment variable
        // (an external credential the user controls in their shell, which we don't clear).
        do {
            try legacyStore.deleteAPIKey()
            AppLog.info(.config, "OllamaAccountsStore: cleared legacy file copy after migration")
        } catch {
            AppLog.warn(.config, "OllamaAccountsStore: failed to clear legacy file copy: \(error.localizedDescription)")
        }
    }

    /// Add a legacy cookie as an account iff it isn't already present in ANY record — active OR
    /// tombstoned. Extracted from `migrateLegacyAccount` so the resurrection guard is unit-testable.
    /// Checking only active records made a *deleted* account resurrect on every launch (its tombstoned
    /// cookie looked "new" and got re-added); a deleted cookie must stay deleted.
    func migrateCookieIfNeeded(_ cookie: String) {
        guard !records.contains(where: { $0.sessionCookie == cookie }) else {
            AppLog.info(.config, "OllamaAccountsStore: cookie already present (active or deleted), skipping migration")
            return
        }

        // Next available account ID across ALL records (incl. tombstones) for unique IDs.
        let maxID = records.map { $0.id }.max()
        let nextID = maxID.map { $0 + 1 } ?? 0

        AppLog.info(.config, "OllamaAccountsStore: migrating legacy cookie as account \(nextID)")
        records.append(OllamaAccountRecord(
            id: nextID,
            sessionCookie: cookie,
            discoveredLabel: nil,
            customLabel: nil,
            removedTombstone: false
        ))
        persist()
    }
}
