import Foundation
import os
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - HTML Utilities

extension String {
    
    /// Strips HTML tags using a lightweight regex approach.
    /// Suitable for list views where full HTML rendering isn't needed.
    func strippingHTML() -> String {
        // Decode common HTML entities first
        var result = self
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        
        // Replace <br>, <br/>, <br /> with newlines
        if let brRegex = try? NSRegularExpression(pattern: "<br\\s*/?>", options: .caseInsensitive) {
            result = brRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "\n"
            )
        }
        
        // Replace </p>, </div>, </li> with newlines for paragraph separation
        if let blockRegex = try? NSRegularExpression(pattern: "</(?:p|div|li|h[1-6])>", options: .caseInsensitive) {
            result = blockRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "\n"
            )
        }
        
        // Strip all remaining HTML tags
        if let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            result = tagRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        
        // Clean up excessive whitespace/newlines
        let lines = result.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        return lines.joined(separator: "\n")
    }
    
    /// Converts an HTML string to an `AttributedString` for SwiftUI `Text`.
    /// Falls back to `strippingHTML()` if conversion fails.
    /// Injects base CSS to match the system font appearance.
    @MainActor
    func htmlAttributedString(baseSize: CGFloat = 15) -> AttributedString {
        // Build a color hex for the label color
        let colorHex: String
        #if os(iOS)
        do {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor.label.getRed(&r, green: &g, blue: &b, alpha: &a)
            colorHex = String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        }
        #else
        // macOS: NSColor.labelColor is a catalog color — must convert to sRGB first
        if let rgbColor = NSColor.labelColor.usingColorSpace(.sRGB) {
            colorHex = String(format: "#%02X%02X%02X",
                              Int(rgbColor.redComponent * 255),
                              Int(rgbColor.greenComponent * 255),
                              Int(rgbColor.blueComponent * 255))
        } else {
            colorHex = "#FFFFFF" // Fallback for dark mode
        }
        #endif
        
        let css = """
        <style>
        body {
            font-family: -apple-system, system-ui;
            font-size: \(baseSize)px;
            line-height: 1.4;
            color: \(colorHex);
        }
        a { color: #007AFF; }
        </style>
        """
        let html = css + self
        
        guard let data = html.data(using: .utf8) else {
            return AttributedString(self.strippingHTML())
        }
        
        // NSAttributedString(data:options:.html) internally uses WebKit, which can
        // throw an Objective-C assertion failure (NSException) when called during
        // certain run loop phases (e.g., FBSSceneSnapshotAction for the app switcher).
        // Swift's try/catch cannot intercept ObjC exceptions, so we use an ObjC
        // @try/@catch wrapper to prevent the crash and fall back to strippingHTML().
        var nsAttr: NSAttributedString?
        let error = ObjCExceptionCatcher.catch {
            nsAttr = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
            )
        }
        
        if let error {
            Logger(subsystem: "com.yourpods", category: "html")
                .warning("HTML rendering threw ObjC exception, falling back to stripped text: \(error.localizedDescription)")
            return AttributedString(self.strippingHTML())
        }
        
        guard let nsAttr else {
            return AttributedString(self.strippingHTML())
        }
        
        return AttributedString(nsAttr)
    }
}
