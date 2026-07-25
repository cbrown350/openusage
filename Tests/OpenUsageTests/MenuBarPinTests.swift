import XCTest
@testable import OpenUsage

/// Covers the menu-bar pin model on `LayoutStore`: the ≤2-per-provider rendering cap, denial
/// reasons/notices, order derivation from the Customize order,
/// disabled-provider handling, and persistence across relaunch.
@MainActor
final class MenuBarPinTests: XCTestCase {
    func testNoPinsByDefault() {
        let store = makeStore("default")
        XCTAssertTrue(store.pinnedMetricIDs.isEmpty)
        XCTAssertTrue(store.pinnedGroups.isEmpty)
        XCTAssertEqual(store.menuBarStyle, .text)
    }

    func testPinUnpinPersistsAcrossReload() {
        let defaults = makeDefaults("persist")
        let store = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")

        store.setPinned(true, for: "a.m1")
        XCTAssertTrue(store.isPinned("a.m1"))

        let reloaded = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")
        XCTAssertTrue(reloaded.isPinned("a.m1"))

        reloaded.setPinned(false, for: "a.m1")
        let reloadedAgain = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")
        XCTAssertFalse(reloadedAgain.isPinned("a.m1"))
    }

    func testPerProviderCapBlocksThirdPin() {
        let store = makeStore("perProvider")
        store.setPinned(true, for: "a.m1")
        store.setPinned(true, for: "a.m2")

        XCTAssertFalse(store.canPin("a.m3"))
        store.setPinned(true, for: "a.m3")
        XCTAssertFalse(store.isPinned("a.m3"))
        XCTAssertEqual(store.pinnedCount(forProvider: "a"), 2)

        // An already-pinned id stays pinnable so its toggle can still unpin it.
        XCTAssertTrue(store.canPin("a.m1"))
    }

    func testEachProviderCanPinUpToTwo() {
        let store = makeStore("manyProviders")
        for provider in ["a", "b", "c", "d"] {
            store.setPinned(true, for: "\(provider).m1")
            store.setPinned(true, for: "\(provider).m2")
            XCTAssertFalse(store.canPin("\(provider).m3"))
        }
        XCTAssertEqual(store.pinnedMetricIDs.count, 8)
    }

    func testPinDenialReasonsAndFooterNotice() {
        let store = makeStore("denial")
        XCTAssertNil(store.pinDenialReason("a.m1"))

        store.setPinned(true, for: "a.m1")
        store.setPinned(true, for: "a.m2")
        XCTAssertEqual(store.pinDenialReason("a.m3"), "Up to 2 stars per provider")
        XCTAssertNil(store.pinDenialReason("b.m1"))

        XCTAssertNil(store.pinDenialReason("b.m1"))

        // A denied click surfaces the reason as the transient footer notice and bumps the shake
        // trigger every time, so repeat clicks re-shake even while the text is unchanged.
        XCTAssertNil(store.pinLimitNotice)
        XCTAssertEqual(store.pinNoticeShakeTrigger, 0)
        store.notePinDenied("a.m3")
        XCTAssertEqual(store.pinLimitNotice, "Up to 2 stars per provider")
        XCTAssertEqual(store.pinNoticeShakeTrigger, 1)
        store.notePinDenied("a.m3")
        XCTAssertEqual(store.pinNoticeShakeTrigger, 2)
    }

    func testUnpinFreesAProviderSlot() {
        let store = makeStore("freeSlot")
        store.setPinned(true, for: "a.m1")
        store.setPinned(true, for: "a.m2")
        XCTAssertFalse(store.canPin("a.m3"))

        store.setPinned(false, for: "a.m1")
        XCTAssertTrue(store.canPin("a.m3"))
    }

    func testPinnedGroupsFollowCustomizeOrder() {
        let store = makeStore("order")
        // Pin out of order; expect provider order (a before b) and metric order (m1 before m2).
        store.setPinned(true, for: "b.m2")
        store.setPinned(true, for: "a.m2")
        store.setPinned(true, for: "a.m1")

        XCTAssertEqual(store.pinnedGroups.flatMap { $0.metrics.map(\.id) }, ["a.m1", "a.m2", "b.m2"])
        XCTAssertEqual(store.pinnedGroups.map(\.provider.id), ["a", "b"])
    }

    func testDisabledProviderPinsExcludedFromGroupsButKept() {
        let store = LayoutStore(
            registry: makeRegistry(),
            defaults: makeDefaults("disabled"),
            storageKey: "layout",
            isProviderEnabled: { $0 != "a" }
        )
        store.setPinned(true, for: "a.m1")
        store.setPinned(true, for: "b.m1")

        XCTAssertEqual(store.pinnedGroups.map(\.provider.id), ["b"])
        XCTAssertTrue(store.isPinned("a.m1"))  // membership preserved while hidden
    }

    func testResetToDefaultClearsPins() {
        let store = makeStore("reset")
        store.setPinned(true, for: "a.m1")
        store.resetToDefault()
        XCTAssertTrue(store.pinnedMetricIDs.isEmpty)
    }

    func testMenuBarStylePersists() {
        let defaults = makeDefaults("style")
        let store = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")
        store.menuBarStyle = .bars

        let reloaded = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")
        XCTAssertEqual(reloaded.menuBarStyle, .bars)
    }

    func testInvalidPinnedIDsDroppedOnLoad() {
        let defaults = makeDefaults("invalid")
        defaults.set(["a.m1", "ghost.metric"], forKey: "layout.menuBarPins")
        let store = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")

        XCTAssertTrue(store.isPinned("a.m1"))
        XCTAssertFalse(store.isPinned("ghost.metric"))
    }

    // MARK: - Fixtures

    /// The owner decision for Ollama: a GUI-added Ollama account card auto-pins its default metrics to
    /// the menu bar (so two accounts → two strips), while Claude account cards keep the existing
    /// never-auto-pin behavior.
    func testOllamaAccountCardAutoPinsToMenuBarButClaudeDoesNot() {
        let defaults = makeDefaults("ollama-account-pin")
        // Launch 1: default family cards only — establishes a saved layout with the family defaults pinned.
        _ = LayoutStore(registry: makeFamilyRegistry(accountCards: []), defaults: defaults, storageKey: "layout")

        // Launch 2: an Ollama account card and a Claude account card appear.
        let store = LayoutStore(
            registry: makeFamilyRegistry(accountCards: ["ollama@1", "claude@ab12cd34"]),
            defaults: defaults,
            storageKey: "layout"
        )

        // The new Ollama card's default metrics claim menu-bar space...
        XCTAssertTrue(store.pinnedMetricIDs.contains("ollama@1.session"), "Ollama account card should auto-pin")
        XCTAssertTrue(store.pinnedMetricIDs.contains("ollama@1.weekly"))
        // ...but the Claude account card never auto-pins (behavior unchanged).
        XCTAssertFalse(store.pinnedMetricIDs.contains("claude@ab12cd34.session"), "Claude account card must not auto-pin")
        XCTAssertFalse(store.pinnedMetricIDs.contains("claude@ab12cd34.weekly"))
        // And the Ollama card actually renders in the strip while the Claude card does not.
        let stripProviderIDs = store.pinnedGroups.map(\.provider.id)
        XCTAssertTrue(stripProviderIDs.contains("ollama@1"))
        XCTAssertFalse(stripProviderIDs.contains("claude@ab12cd34"))
    }

    /// A registry of the Ollama + Claude families, each with session/weekly metrics matching the real
    /// `DefaultLayout` ids, plus any extra account cards (`ollama@1`, `claude@ab12cd34`).
    private func makeFamilyRegistry(accountCards: [String]) -> WidgetRegistry {
        let allIDs = ["ollama", "claude"] + accountCards
        let providers = allIDs.map { id in
            Provider(id: id, displayName: id.uppercased(), icon: .providerMark("ollama"))
        }
        let descriptors = providers.flatMap { provider in
            ["session", "weekly"].map { suffix in
                metric(provider, id: "\(provider.id).\(suffix)", label: suffix.capitalized)
            }
        }
        return WidgetRegistry(providers: providers, descriptors: descriptors)
    }

    private func makeStore(_ name: String) -> LayoutStore {
        LayoutStore(registry: makeRegistry(), defaults: makeDefaults(name), storageKey: "layout")
    }

    /// Four providers (a, b, c, d), each with three percent metrics m1/m2/m3, in registry order.
    private func makeRegistry() -> WidgetRegistry {
        let providers = ["a", "b", "c", "d"].map { id in
            Provider(id: id, displayName: id.uppercased(), icon: .providerMark("cursor"))
        }
        let descriptors = providers.flatMap { provider in
            (1...3).map { n in metric(provider, id: "\(provider.id).m\(n)", label: "M\(n)") }
        }
        return WidgetRegistry(providers: providers, descriptors: descriptors)
    }

    private func metric(_ provider: Provider, id: String, label: String) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: provider.id,
            metricLabel: label,
            sample: WidgetData(
                title: label,
                icon: provider.icon,
                kind: .percent,
                used: 10,
                limit: 100
            )
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.MenuBarPin.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
