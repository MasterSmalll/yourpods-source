// ─── GroupsSyncCapable ────────────────────────────────────────────────────
// Thin protocol enabling push-then-pull group sync without coupling
// PodcastManager to the concrete YourPodsProClient actor.
//
// Implemented by:
//   - YourPodsProClient (production)
//   - SpyGroupsProClient (tests)
// ─────────────────────────────────────────────────────────────────────────

/// Capability interface for the two groups sync network calls.
///
/// Conforming types must implement push (`syncGroups`) and pull (`getGroups`)
/// so `PodcastManager.syncGroupsPushThenPull` can enforce push-before-pull
/// ordering without depending on the concrete `YourPodsProClient` actor.
protocol GroupsSyncCapable {
    /// Push the full local groups list to the server (replaces server state).
    func syncGroups(profileName: String, groups: [ProGroup]) async throws

    /// Pull the current groups list from the server for the given profile.
    func getGroups(profileName: String) async throws -> ProGroupsResponse?
}
