import XCTest
import SwiftUI
@testable import YourPods

/// Regression guard for the glass environment-trap crash and its whole class of crashes.
///
/// The glass modifiers used to read `@Environment(SettingsManager.self)`
/// **unconditionally**, which traps (`EXC_BREAKPOINT` in
/// `EnvironmentValues.subscript.getter`) whenever a glass surface renders in a
/// subtree that never received `SettingsManager` (scene-sibling overlays,
/// macOS sheet windows, UIHostingController hosts, extension targets).
///
/// The fix routes appearance through a custom `\.glassAppearance`
/// `EnvironmentKey` with a `.regular` default, so the modifiers can never trap
/// regardless of where they are applied.
@MainActor
final class GlassEnvironmentSafetyTests: XCTestCase {

    /// The key resolves to a sensible default when no provider exists — this is
    /// what makes the modifier structurally incapable of trapping.
    func test_glassAppearanceEnvironmentKey_defaultsToRegular() {
        XCTAssertEqual(EnvironmentValues().glassAppearance, .regular)
    }

    /// A glass surface must render with NO SettingsManager in the environment.
    /// Pre-fix this trapped; post-fix it resolves to the `.regular` default.
    func test_glassModifier_rendersWithoutSettingsManager() {
        let view = Text("Hi").padding().yourPodsGlass(role: .overlay)
        let renderer = ImageRenderer(content: view)
        XCTAssertNotNil(renderer.uiImage,
                        "glass surface must render without SettingsManager injected")
    }

    func test_glassFillModifier_rendersWithoutSettingsManager() {
        let view = Color.clear.frame(width: 40, height: 40).yourPodsGlassFill()
        let renderer = ImageRenderer(content: view)
        XCTAssertNotNil(renderer.uiImage)
    }

    /// Explicitly seeding the key without a SettingsManager must also be safe.
    func test_glassModifier_respectsExplicitAppearance_withoutSettingsManager() {
        let view = Text("Hi").yourPodsGlass(role: .card)
            .environment(\.glassAppearance, .clear)
        let renderer = ImageRenderer(content: view)
        XCTAssertNotNil(renderer.uiImage)
    }
}
