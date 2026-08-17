import XCTest
@testable import YourPods

/// Regression test for the startup overlay crash (a glass environment trap).
///
/// **Root cause:** `startupLoadingOverlay` in `YourPodsApp.body` used
/// `.yourPodsGlass()`, which reads `@Environment(SettingsManager.self)`.
/// However, the `.environment(settingsManager)` injections were applied to
/// `ContentView` only — the overlay was a *sibling* inside the `ZStack`,
/// not a child, so it never received the injection.  When the overlay
/// rendered (returning users with a non-empty actionMap), SwiftUI hit
/// `preconditionFailure` in `EnvironmentValues.subscript.getter` → crash.
///
/// **Fix:** Move `.environment()` injections from `ContentView` to the
/// enclosing `ZStack` so all children share the same environments.
///
/// **Verification strategy:** We can't easily render `YourPodsApp` in a
/// unit test, but we CAN verify the structural invariant that the fix
/// preserves: the environment injections must be at or above the nearest
/// common ancestor of `ContentView` and `startupLoadingOverlay`.
///
/// This test verifies the fix by asserting that the `YourPodsApp.body`
/// source structure places `.environment()` calls on the `ZStack` (parent
/// of both children) rather than on `ContentView` alone.
final class StartupOverlayEnvironmentTests: XCTestCase {
    
    /// Verify that SettingsManager environment is available to the startup
    /// overlay — by reading the source file and checking that `.environment()`
    /// calls are NOT exclusively on `ContentView()`.
    ///
    /// This is a structural/smoke test. A more robust approach would be a
    /// SwiftUI view host test, but the crash was deterministic and the fix
    /// is a simple relocation of modifier calls.
    func testEnvironmentInjectionsAreOnZStackNotContentView() throws {
        // Read YourPodsApp.swift source
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // YourPodsTests/
            .deletingLastPathComponent() // YourPods project root
            .appendingPathComponent("YourPods/YourPods/YourPodsApp.swift")
        
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        
        // Find the body property
        guard let bodyLineIndex = lines.firstIndex(where: { $0.contains("var body: some Scene") }) else {
            XCTFail("Could not find `var body: some Scene` in YourPodsApp.swift")
            return
        }
        
        // Find ContentView() line
        guard let contentViewLineIndex = lines[bodyLineIndex...].firstIndex(where: { $0.contains("ContentView()") }) else {
            XCTFail("Could not find ContentView() in body")
            return
        }
        
        // Check the lines between ContentView() and the next closing brace at the same indentation.
        // The .environment() calls should NOT be directly on ContentView.
        let contentViewLine = lines[contentViewLineIndex]
        let contentViewIndent = contentViewLine.prefix(while: { $0 == " " }).count
        
        // Look at the next few lines after ContentView() — they should NOT contain .environment(settingsManager)
        // at ContentView's child indentation level (contentViewIndent + 4 for chained modifiers)
        let chainedModifierIndent = contentViewIndent + 4
        
        var foundEnvironmentOnContentView = false
        for i in (contentViewLineIndex + 1)..<min(contentViewLineIndex + 20, lines.count) {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            let indent = lines[i].prefix(while: { $0 == " " }).count
            
            // If we hit a line at the same or lesser indent as ContentView, we've exited its modifier chain
            if indent <= contentViewIndent && !line.isEmpty {
                break
            }
            
            // Check if .environment(settingsManager) is chained directly on ContentView
            if indent == chainedModifierIndent && line.contains(".environment(settingsManager)") {
                foundEnvironmentOnContentView = true
            }
        }
        
        XCTAssertFalse(
            foundEnvironmentOnContentView,
            "Environment injections must be on the ZStack (common ancestor), not on ContentView alone. " +
            "The startupLoadingOverlay is a sibling of ContentView and needs access to SettingsManager " +
            "for .yourPodsGlass()."
        )
        
        // Also verify the .environment() calls exist somewhere in the body (sanity check)
        let bodySection = lines[bodyLineIndex...].prefix(100).joined(separator: "\n")
        XCTAssertTrue(
            bodySection.contains(".environment(settingsManager)"),
            "SettingsManager must be injected somewhere in the app body"
        )
        XCTAssertTrue(
            bodySection.contains(".environment(playerManager)"),
            "PlayerManager must be injected somewhere in the app body"
        )
    }
    
    /// Verify that the startupLoadingOverlay uses yourPodsGlass (regression guard).
    /// If someone removes the glass modifier, this test reminds them that the
    /// environment injection was specifically moved to support it.
    func testStartupOverlayUsesGlassModifier() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("YourPods/YourPods/YourPodsApp.swift")
        
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        
        // Find startupLoadingOverlay
        XCTAssertTrue(
            source.contains("startupLoadingOverlay"),
            "startupLoadingOverlay should exist in YourPodsApp"
        )
        
        // Find the overlay definition and verify it uses yourPodsGlass
        let lines = source.components(separatedBy: "\n")
        if let overlayDefIndex = lines.firstIndex(where: { $0.contains("startupLoadingOverlay: some View") }) {
            let overlaySection = lines[overlayDefIndex...].prefix(20).joined(separator: "\n")
            XCTAssertTrue(
                overlaySection.contains(".yourPodsGlass"),
                "startupLoadingOverlay should use .yourPodsGlass() — if removed, " +
                "the environment injection relocation may no longer be needed but should be kept for safety"
            )
        }
    }

    /// The glass appearance must be seeded into the environment at the app root so
    /// every glass surface (incl. the startup overlay) renders the user's chosen
    /// style. The `\.glassAppearance` key has a `.regular` default, so a missing
    /// seed can no longer crash — but it would silently ignore the user's setting.
    func testGlassAppearanceIsSeededAtAppRoot() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("YourPods/YourPods/YourPodsApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains(".environment(\\.glassAppearance, settingsManager.glassAppearance)"),
            "YourPodsApp must seed .environment(\\.glassAppearance, settingsManager.glassAppearance) " +
            "so the user's Glass Style flows to every glass surface."
        )
    }
}
