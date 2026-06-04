import SwiftUI
#if os(iOS)
import UIKit

// MARK: - Imperative Share Sheet Presenter

/// Presents UIActivityViewController directly from the topmost UIKit view
/// controller, completely bypassing SwiftUI's `.sheet()` presentation.
///
/// Call `SharePresenter.present(items:)` directly from button actions
/// instead of toggling a `@State` binding.
enum SharePresenter {
    
    /// Present the system share sheet with the given items.
    /// Safe to call from any context — handles VC hierarchy walking
    /// and Menu/popover dismissal timing automatically.
    static func present(items: [Any]) {
        guard !items.isEmpty else { return }
        
        // Short delay to let SwiftUI Menu/popover dismissal complete.
        // Without this, presentation can be swallowed if a Menu is
        // still animating its dismissal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let activityVC = UIActivityViewController(
                activityItems: items,
                applicationActivities: nil
            )
            
            guard let presenter = Self.topViewController() else { return }
            
            // iPad popover anchor
            activityVC.popoverPresentationController?.sourceView = presenter.view
            activityVC.popoverPresentationController?.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.maxY - 50,
                width: 0, height: 0
            )
            activityVC.popoverPresentationController?.permittedArrowDirections = .down
            
            presenter.present(activityVC, animated: true)
        }
    }
    
    /// Walk the VC presentation chain to find the topmost presented controller.
    private static func topViewController() -> UIViewController? {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = windowScene.windows.first?.rootViewController else {
            return nil
        }
        
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
#endif

#if os(macOS)
import AppKit

/// macOS equivalent of SharePresenter using NSSharingServicePicker.
enum SharePresenter {
    
    /// Present the system share picker with the given items.
    static func present(items: [Any]) {
        guard !items.isEmpty else { return }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let window = NSApplication.shared.keyWindow,
                  let contentView = window.contentView else { return }
            
            let picker = NSSharingServicePicker(items: items)
            let rect = CGRect(
                x: contentView.bounds.midX,
                y: contentView.bounds.midY,
                width: 0, height: 0
            )
            picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
        }
    }
}
#endif
