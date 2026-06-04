import Foundation
import os

#if os(macOS)
import AppKit

/// Custom NSApplication subclass that logs exception details before crashing.
/// This intercepts Objective-C exceptions that AppKit catches during view layout,
/// letting us see the actual error message instead of just `_crashOnException:`.
class YourPodsApplication: NSApplication {
    private static let logger = Logger(subsystem: "com.yourpods", category: "crash")
    
    override func reportException(_ exception: NSException) {
        let message = """
        ⚠️ CAUGHT EXCEPTION during view layout:
        Name: \(exception.name.rawValue)
        Reason: \(exception.reason ?? "unknown")
        User Info: \(String(describing: exception.userInfo))
        Call Stack:
        \(exception.callStackSymbols.joined(separator: "\n"))
        """
        Self.logger.fault("\(message)")
        
        // Write to file for easy retrieval
        let crashLog = FileManager.default.temporaryDirectory.appendingPathComponent("yourpods_crash.log")
        try? message.write(to: crashLog, atomically: true, encoding: .utf8)
        
        // Print to stderr so it shows in Xcode console
        fputs("\n\(message)\n", stderr)
        
        // Call super to get default behavior (crash)
        super.reportException(exception)
    }
}
#endif
