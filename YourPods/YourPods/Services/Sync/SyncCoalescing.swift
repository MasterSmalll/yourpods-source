import Foundation

/// Decides whether an incoming `refreshAndSync` request may join an in-flight
/// sync (single-flight coalescing) or must start its own.
enum SyncCoalescing {
    /// - Parameters:
    ///   - incomingIsBackground: whether the new request is a background sync.
    ///   - inFlightIsBackground: whether the in-flight sync is a background sync.
    /// - Returns: `true` if the incoming request may join the in-flight sync.
    static func canJoinInFlight(incomingIsBackground: Bool, inFlightIsBackground: Bool) -> Bool {
        // The only disallowed combination is a foreground request joining an
        // in-flight background sync: the background pipeline defers RSS refresh to
        // last and is cancellation-prone, so the foreground caller would inherit a
        // sync that never refreshes feeds. Every other combination may coalesce.
        !(incomingIsBackground == false && inFlightIsBackground == true)
    }
}
