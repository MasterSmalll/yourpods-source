import Foundation
import WidgetKit
import os

/// Single write-path for complication data. Change-gated: identical state must
/// not call WidgetCenter (complication reloads have a hard daily budget).
enum WatchComplicationRefresher {
    private static let logger = Logger(subsystem: "com.yourpods", category: "WatchComplication")

    static func update(_ mutate: (inout ComplicationData) -> Void) {
        var data = ComplicationDataStore.shared.read()
        let before = data
        mutate(&data)
        data.lastUpdated = Date()
        guard data.meaningfullyDiffers(from: before) else {
            logger.debug("Complication unchanged — skipping reload")
            return
        }
        ComplicationDataStore.shared.write(data)
        WidgetCenter.shared.reloadAllTimelines()
        logger.debug("Complication updated (playing: \(data.isPlaying), queue: \(data.queueCount))")
    }
}
