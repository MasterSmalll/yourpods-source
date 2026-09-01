import Foundation
import WatchConnectivity
import os

/// Ships locally-captured podcast moments from the Watch to the companion iPhone app.
///
/// Captures remain in WatchAudioManager/UserDefaults as the source of truth. This
/// coordinator only tracks which UUIDs have been accepted for delivery by
/// WatchConnectivity, so a run without the iPhone is safe: transferUserInfo queues
/// the payload until the phone is available again.
final class CapturedMomentSyncCoordinator {
    static let shared = CapturedMomentSyncCoordinator()

    private let logger = Logger(subsystem: "com.yourpods", category: "CapturedMomentSync")
    private let momentsKey = "watch_captured_moments_v1"
    private let enqueuedKey = "watch_captured_moments_enqueued_v1"
    private var observer: NSObjectProtocol?
    private var enqueuedIds: Set<String>
    private var started = false

    private init() {
        enqueuedIds = Set(UserDefaults.standard.stringArray(forKey: enqueuedKey) ?? [])
    }

    func start() {
        guard !started else {
            flushPendingMoments()
            return
        }
        started = true

        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            self?.flushPendingMoments()
        }

        flushPendingMoments()
    }

    func flushPendingMoments() {
        let session = WCSession.default
        guard session.activationState == .activated else {
            logger.debug("Capture sync waiting for WCSession activation")
            return
        }
        guard session.isCompanionAppInstalled else {
            logger.debug("Capture sync waiting for Podcast Marker iPhone companion")
            return
        }
        guard let data = UserDefaults.standard.data(forKey: momentsKey),
              let moments = try? JSONDecoder().decode([CapturedMoment].self, from: data) else {
            return
        }

        for moment in moments where !enqueuedIds.contains(moment.id.uuidString) {
            send(moment, via: session)
        }
    }

    private func send(_ moment: CapturedMoment, via session: WCSession) {
        let id = moment.id.uuidString
        let payload: [String: Any] = [
            "command": "captured_moment",
            "id": id,
            "episodeId": moment.episodeId,
            "podcastTitle": moment.podcastTitle,
            "episodeTitle": moment.episodeTitle,
            "timestampSec": moment.timestampSec,
            "capturedAt": moment.capturedAt.timeIntervalSince1970,
        ]

        if session.isReachable {
            session.sendMessage(payload, replyHandler: { [weak self] reply in
                guard (reply["status"] as? String) == "ok" else { return }
                DispatchQueue.main.async {
                    self?.markEnqueued(id)
                }
            }, errorHandler: { [weak self] error in
                self?.logger.error("Live captured-moment send failed: \(error.localizedDescription); queueing durable transfer")
                _ = session.transferUserInfo(payload)
                DispatchQueue.main.async {
                    self?.markEnqueued(id)
                }
            })
        } else {
            _ = session.transferUserInfo(payload)
            markEnqueued(id)
        }
    }

    private func markEnqueued(_ id: String) {
        guard enqueuedIds.insert(id).inserted else { return }
        UserDefaults.standard.set(Array(enqueuedIds), forKey: enqueuedKey)
        logger.info("Captured moment accepted for iPhone delivery: \(id)")
    }
}
