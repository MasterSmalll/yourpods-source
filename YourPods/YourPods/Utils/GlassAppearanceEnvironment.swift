import SwiftUI

/// Carries the user's chosen `GlassAppearance` through the SwiftUI environment.
///
/// The glass modifiers (`YourPodsGlassModifier` / `YourPodsGlassFillModifier`)
/// read appearance via this key instead of `@Environment(SettingsManager.self)`.
///
/// **Why a custom key and not the manager:** reading `@Environment(SomeObservable.self)`
/// *traps* (`EXC_BREAKPOINT` in `EnvironmentValues.subscript.getter`) when that type
/// was never injected — and glass surfaces render in many non-inheriting contexts
/// (scene-sibling overlays, macOS sheet windows, `UIHostingController` hosts, even
/// separate-process extension targets). A custom `EnvironmentKey` always resolves to
/// its `defaultValue`, so the glass system is *structurally incapable* of trapping
/// wherever it is applied. Root cause of the glass environment-trap crash.
///
/// The default (`.regular`) matches `SettingsManager.glassAppearance`'s own default,
/// so any context that never receives a value renders identically to a freshly
/// installed app — no first-frame flicker.
private struct GlassAppearanceKey: EnvironmentKey {
    static let defaultValue: GlassAppearance = .regular
}

extension EnvironmentValues {
    /// The active glass appearance. Seeded once at the app root from
    /// `SettingsManager.glassAppearance`; falls back to `.regular` elsewhere.
    var glassAppearance: GlassAppearance {
        get { self[GlassAppearanceKey.self] }
        set { self[GlassAppearanceKey.self] = newValue }
    }
}
