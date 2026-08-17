import SwiftUI

/// Semantic roles for glass surfaces — lets the modifier pick the right
/// glass variant or material fallback per context.
enum GlassRole {
    /// Persistent floating chrome (NowPlayingBar, capsule buttons)
    case floatingChrome
    /// Full-screen player surfaces
    case player
    /// Card surfaces in scroll content (HomeView cards, search results)
    case card
    /// Small interactive controls (sleep timer capsules)
    case control
    /// Placeholder / loading overlays
    case overlay
}

/// The resolved rendering decision for a glass surface, independent of SwiftUI.
///
/// Extracted from the glass modifiers so the appearance / accessibility
/// precedence is pure and unit-testable (no SwiftUI host required).
enum ResolvedGlassStyle: Equatable {
    /// Opaque classic material (Reduce Transparency, Classic setting, or pre-iOS-26).
    case classicMaterial
    /// Maximum-transparency clear glass.
    case clearGlass
    /// Standard iOS 26 glass.
    case regularGlass
    /// High-contrast glass (system Increase Contrast or High Contrast Glass setting).
    case highContrastGlass
}

/// Pure resolution of which glass treatment a surface should use.
///
/// Priority (highest wins):
/// 1. Reduce Transparency → classic (opaque material)
/// 2. Glass Style == `.classic` → classic
/// 3. iOS < 26 (glass API unavailable) → classic
/// 4. Increase Contrast OR Glass Style == `.highContrast` → high-contrast glass
/// 5. Glass Style == `.clear` → clear glass — **except** for over-artwork roles
///    (`.player`, `.floatingChrome`), where clear glass hurts text legibility, so
///    it escalates to regular glass.
/// 6. otherwise → regular glass
func resolveGlassStyle(
    appearance: GlassAppearance,
    reduceTransparency: Bool,
    contrast: ColorSchemeContrast,
    isOS26Available: Bool,
    role: GlassRole
) -> ResolvedGlassStyle {
    if reduceTransparency || appearance == .classic { return .classicMaterial }
    if !isOS26Available { return .classicMaterial }
    if contrast == .increased || appearance == .highContrast { return .highContrastGlass }
    if appearance == .clear {
        // Over-artwork surfaces escalate clear → regular for legibility.
        let isOverArtwork = (role == .player || role == .floatingChrome)
        return isOverArtwork ? .regularGlass : .clearGlass
    }
    return .regularGlass
}

/// Central modifier that controls glass vs classic material rendering.
///
/// This is the **single source of truth** for the Liquid Glass ↔ Classic
/// decision. Every custom surface uses `.yourPodsGlass(role:)` instead
/// of raw `.ultraThinMaterial`, so the user toggle, the tint levels,
/// the iOS-17 fallback, and the accessibility behavior live in one place.
///
/// Appearance flows in via the `\.glassAppearance` `EnvironmentKey` (seeded at
/// the app root from `SettingsManager`), **not** `@Environment(SettingsManager.self)`.
/// That key has a `.regular` default, so this modifier can never trap no matter
/// where it is applied — see `GlassAppearanceEnvironment.swift`.
///
/// Decision priority lives in the pure `resolveGlassStyle(...)`; per-role
/// legibility (scrim + escalation for over-artwork surfaces) is applied here.
struct YourPodsGlassModifier: ViewModifier {
    let role: GlassRole
    let cornerRadius: CGFloat

    @Environment(\.glassAppearance) private var glassAppearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let style = resolveGlassStyle(
            appearance: glassAppearance,
            reduceTransparency: reduceTransparency,
            contrast: contrast,
            isOS26Available: Self.isOS26GlassAvailable,
            role: role
        )
        switch style {
        case .classicMaterial:
            classicBackground(content: content)
        case .clearGlass, .regularGlass, .highContrastGlass:
            glassBody(content: content, style: style)
        }
    }

    /// Whether the iOS 26 glass API is available at runtime.
    static var isOS26GlassAvailable: Bool {
        if #available(iOS 26.0, watchOS 26.0, macOS 26.0, *) { return true } else { return false }
    }

    @ViewBuilder
    private func classicBackground(content: Content) -> some View {
        content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// Availability-gated bridge: `resolveGlassStyle` only returns a glass case
    /// when `isOS26GlassAvailable`, so the `else` is unreachable but required to
    /// satisfy the `@available` check on `glassBackground`.
    @ViewBuilder
    private func glassBody(content: Content, style: ResolvedGlassStyle) -> some View {
        if #available(iOS 26.0, watchOS 26.0, macOS 26.0, *) {
            glassBackground(content: content, style: style)
        } else {
            classicBackground(content: content)
        }
    }

    /// A subtle scrim placed between the glass and the content to keep text
    /// legible over busy artwork. Only over-artwork roles (`.player`,
    /// `.floatingChrome`) get a non-clear scrim; cards/controls stay clean.
    /// Adapts to color scheme so it anchors `.primary` text in both modes.
    private var legibilityScrim: Color {
        guard role == .player || role == .floatingChrome else { return .clear }
        return (colorScheme == .dark ? Color.black : Color.white).opacity(0.22)
    }

    /// High-contrast tint, scheme-aware: a white lift reads in dark mode but adds
    /// almost nothing in light mode, so use a dark tint there for real separation.
    private var highContrastTint: Color {
        (colorScheme == .dark ? Color.white : Color.black).opacity(0.15)
    }

    @available(iOS 26.0, watchOS 26.0, macOS 26.0, *)
    @ViewBuilder
    private func glassBackground(content: Content, style: ResolvedGlassStyle) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        switch style {
        case .highContrastGlass:
            // Interactive glass with a scheme-aware tint for extra separation.
            content
                .background(legibilityScrim, in: shape)
                .glassEffect(.regular.interactive().tint(highContrastTint), in: shape)
        case .clearGlass:
            // Clear: maximum transparency. (Over-artwork roles never reach here —
            // resolveGlassStyle escalates them to regular.)
            content
                .background(legibilityScrim, in: shape)
                .glassEffect(.clear, in: shape)
        case .regularGlass:
            content
                .background(legibilityScrim, in: shape)
                .glassEffect(.regular, in: shape)
        case .classicMaterial:
            classicBackground(content: content)
        }
    }
}

/// Modifier for surfaces that use `.fill()` instead of `.background()`.
/// Used by PlayerView artwork placeholder and EpisodeDetailSheet placeholder.
///
/// Reads appearance via `\.glassAppearance` (never `SettingsManager`) so it
/// cannot trap — same rationale as `YourPodsGlassModifier`.
struct YourPodsGlassFillModifier: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.glassAppearance) private var glassAppearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let style = resolveGlassStyle(
            appearance: glassAppearance,
            reduceTransparency: reduceTransparency,
            contrast: contrast,
            isOS26Available: YourPodsGlassModifier.isOS26GlassAvailable,
            role: .card
        )
        switch style {
        case .classicMaterial:
            // Reduce Transparency / Classic / pre-iOS-26: apply an explicit opaque
            // material backing so a caller relying solely on this modifier is never
            // left fully transparent (previously returned bare content).
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        case .clearGlass, .regularGlass, .highContrastGlass:
            glassBody(content: content, style: style)
        }
    }

    private var highContrastTint: Color {
        (colorScheme == .dark ? Color.white : Color.black).opacity(0.15)
    }

    @ViewBuilder
    private func glassBody(content: Content, style: ResolvedGlassStyle) -> some View {
        if #available(iOS 26.0, watchOS 26.0, macOS 26.0, *) {
            let shape = RoundedRectangle(cornerRadius: cornerRadius)
            switch style {
            case .highContrastGlass:
                content.glassEffect(.regular.interactive().tint(highContrastTint), in: shape)
            case .clearGlass:
                content.glassEffect(.clear, in: shape)
            case .regularGlass:
                content.glassEffect(.regular, in: shape)
            case .classicMaterial:
                content.background(.ultraThinMaterial, in: shape)
            }
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

extension View {
    /// Apply the YourPods glass/material treatment.
    ///
    /// Replaces raw `.background(.ultraThinMaterial)` everywhere.
    /// Reads the user's glass preference, accessibility settings, and OS version
    /// to decide between Liquid Glass and classic materials.
    func yourPodsGlass(role: GlassRole = .card, cornerRadius: CGFloat = 16) -> some View {
        modifier(YourPodsGlassModifier(role: role, cornerRadius: cornerRadius))
    }

    /// Apply glass treatment to `.fill()` surfaces (artwork placeholders).
    ///
    /// On iOS 26+ with glass enabled, overlays a glass effect on the fill.
    /// On older OS or with classic/accessibility settings, passes through unchanged
    /// (the existing `.fill(.ultraThinMaterial)` remains).
    func yourPodsGlassFill(cornerRadius: CGFloat = 16) -> some View {
        modifier(YourPodsGlassFillModifier(cornerRadius: cornerRadius))
    }
}
