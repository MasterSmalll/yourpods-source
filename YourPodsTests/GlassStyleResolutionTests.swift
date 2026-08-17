import XCTest
import SwiftUI
@testable import YourPods

/// Unit tests for the pure glass-style resolution logic extracted from
/// `YourPodsGlassModifier` / `YourPodsGlassFillModifier`.
///
/// This locks the exact decision precedence (Reduce Transparency / Increase
/// Contrast / user Glass Style / OS availability) plus the per-role legibility
/// escalation, with no SwiftUI host required. It is the regression guard for
/// the "tint vs non-tinted" accessibility behavior (glass environment-trap follow-up).
final class GlassStyleResolutionTests: XCTestCase {

    // MARK: - Reduce Transparency wins over everything (highest priority)

    func test_reduceTransparency_forcesClassicMaterial_regardlessOfAppearance() {
        for appearance in GlassAppearance.allCases {
            let style = resolveGlassStyle(
                appearance: appearance,
                reduceTransparency: true,
                contrast: .increased,
                isOS26Available: true,
                role: .card
            )
            XCTAssertEqual(style, .classicMaterial,
                           "Reduce Transparency must force opaque material for \(appearance)")
        }
    }

    // MARK: - Classic user setting

    func test_classicAppearance_resolvesToClassicMaterial() {
        let style = resolveGlassStyle(
            appearance: .classic, reduceTransparency: false,
            contrast: .standard, isOS26Available: true, role: .card
        )
        XCTAssertEqual(style, .classicMaterial)
    }

    // MARK: - OS availability fallback

    func test_preOS26_resolvesToClassicMaterial_evenWhenGlassRequested() {
        let style = resolveGlassStyle(
            appearance: .regular, reduceTransparency: false,
            contrast: .standard, isOS26Available: false, role: .card
        )
        XCTAssertEqual(style, .classicMaterial)
    }

    // MARK: - High contrast (system Increase Contrast OR user High Contrast Glass)

    func test_increaseContrast_resolvesToHighContrastGlass() {
        let style = resolveGlassStyle(
            appearance: .regular, reduceTransparency: false,
            contrast: .increased, isOS26Available: true, role: .card
        )
        XCTAssertEqual(style, .highContrastGlass)
    }

    func test_highContrastAppearance_resolvesToHighContrastGlass() {
        let style = resolveGlassStyle(
            appearance: .highContrast, reduceTransparency: false,
            contrast: .standard, isOS26Available: true, role: .card
        )
        XCTAssertEqual(style, .highContrastGlass)
    }

    // MARK: - Standard glass variants

    func test_clearAppearance_contentRole_resolvesToClearGlass() {
        let style = resolveGlassStyle(
            appearance: .clear, reduceTransparency: false,
            contrast: .standard, isOS26Available: true, role: .card
        )
        XCTAssertEqual(style, .clearGlass)
    }

    func test_regularAppearance_resolvesToRegularGlass() {
        let style = resolveGlassStyle(
            appearance: .regular, reduceTransparency: false,
            contrast: .standard, isOS26Available: true, role: .card
        )
        XCTAssertEqual(style, .regularGlass)
    }

    // MARK: - Per-role legibility escalation (over-artwork surfaces)

    func test_clearAppearance_playerRole_escalatesToRegularGlass() {
        let style = resolveGlassStyle(
            appearance: .clear, reduceTransparency: false,
            contrast: .standard, isOS26Available: true, role: .player
        )
        XCTAssertEqual(style, .regularGlass,
                       "Player surfaces sit over artwork — clear glass must escalate to regular for legibility")
    }

    func test_clearAppearance_floatingChromeRole_escalatesToRegularGlass() {
        let style = resolveGlassStyle(
            appearance: .clear, reduceTransparency: false,
            contrast: .standard, isOS26Available: true, role: .floatingChrome
        )
        XCTAssertEqual(style, .regularGlass)
    }

    func test_clearAppearance_controlAndOverlayRoles_stayClearGlass() {
        for role in [GlassRole.control, .overlay, .card] {
            let style = resolveGlassStyle(
                appearance: .clear, reduceTransparency: false,
                contrast: .standard, isOS26Available: true, role: role
            )
            XCTAssertEqual(style, .clearGlass,
                           "\(role) is not over artwork — clear glass should be preserved")
        }
    }

    func test_perRoleEscalation_doesNotOverrideHighContrast() {
        let style = resolveGlassStyle(
            appearance: .highContrast, reduceTransparency: false,
            contrast: .standard, isOS26Available: true, role: .player
        )
        XCTAssertEqual(style, .highContrastGlass)
    }

    // MARK: - Precedence ordering

    func test_reduceTransparency_winsOver_clear() {
        let style = resolveGlassStyle(
            appearance: .clear, reduceTransparency: true,
            contrast: .standard, isOS26Available: true, role: .player
        )
        XCTAssertEqual(style, .classicMaterial)
    }

    func test_reduceTransparency_winsOver_increaseContrast() {
        let style = resolveGlassStyle(
            appearance: .regular, reduceTransparency: true,
            contrast: .increased, isOS26Available: true, role: .card
        )
        XCTAssertEqual(style, .classicMaterial)
    }

    func test_increaseContrast_winsOver_clear() {
        let style = resolveGlassStyle(
            appearance: .clear, reduceTransparency: false,
            contrast: .increased, isOS26Available: true, role: .card
        )
        XCTAssertEqual(style, .highContrastGlass)
    }
}
