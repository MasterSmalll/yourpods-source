import SwiftUI

// MARK: - Cross-Platform View Extensions

/// Provides macOS-safe versions of iOS-only modifiers.
/// These no-op on macOS so views can share code without #if os() at every call site.

extension View {
    /// Cross-platform wrapper for `.navigationBarTitleDisplayMode(.inline)`.
    /// No-op on macOS; applies `.inline` on iOS.
    @ViewBuilder
    func inlineNavigationBarTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
