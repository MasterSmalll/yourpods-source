#if os(iOS)
import SwiftUI
import AVKit

/// A SwiftUI wrapper around `AVRoutePickerView` — the system AirPlay / Bluetooth
/// output picker. Tapping it presents the system route sheet; the icon highlights
/// (`activeTintColor`) when an external route is active. This is the only
/// "playing on external" indicator — no separate text label.
///
/// Placed beside the transport controls; sized to match the adjacent glyphs and
/// positioned to leave room for a future sibling output button (e.g. Cast).
struct RoutePickerView: UIViewRepresentable {
    var tint: UIColor
    var activeTint: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = tint
        view.activeTintColor = activeTint
        view.prioritizesVideoDevices = false
        // AVRoutePickerView ships a built-in VoiceOver label; set explicitly to
        // satisfy the accessibility release gate and keep copy consistent.
        view.accessibilityLabel = "Audio output"
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tint
        uiView.activeTintColor = activeTint
    }
}
#endif
