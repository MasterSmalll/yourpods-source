import Foundation

/// Extension to detect cancellation errors from any source.
///
/// When a Swift Task is cancelled:
/// - `async` code throws `CancellationError`
/// - `URLSession.data(for:)` throws `URLError(.cancelled)` (code -999)
/// - `YourPodsProClient.translateNetworkError` maps to `.requestCancelled`
///
/// This extension unifies all three checks into a single `.isCancellationError` property,
/// so callers don't need to handle each variant separately.
extension Error {
    /// Returns `true` if this error represents a task/request cancellation,
    /// regardless of its concrete type.
    var isCancellationError: Bool {
        // Swift structured concurrency cancellation
        if self is CancellationError { return true }
        
        // URLSession cancellation (code -999)
        if let urlError = self as? URLError, urlError.code == .cancelled { return true }
        
        // YourPodsProClient translated cancellation
        if let proError = self as? YourPodsProError, proError == .requestCancelled { return true }
        
        return false
    }
}
