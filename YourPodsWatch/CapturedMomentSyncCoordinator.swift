import Foundation
import WatchConnectivity
import os

/// Ships locally-captured podcast moments from the Watch to the companion iPhone app.
///
/// Captures remain in WatchAudioManager/UserDefaults as the source of truth. A capture
/// is only marked delivered after the iPhone acknowledges a live message. Durable
/// transferUserInfo sends remain retryable until a later live acknowledgement arrives.
/// The iPhone store deduplicates by UUID, so retries are safe.
final class CapturedMomentSyncCoordinator {
    static let shared = CapturedMomentSyncCoordinator()

    private let logger = Logger(subsystem: "com.yourpods", category: "CapturedMomentSync")
    private let momentsKey = "watch_captured_moments_v1"
    // New key intentionally ignores the old V1 "enqueued" state, which could mark
    // a transfer complete before it had actually reached the iPhone.
    private let deliveredKey = "watch_captured_moments_delivered_v2"
    private var observer: NSObjectProtocol?
    private var deliveredIds: Set<String>
    private var inFlightIds: Set<String> = []
    private var started = false

    private init() {
        deliveredIds = Set(UserDefaults.standard.stringArray(forKey: deliveredKey) ?? [])
    }

    func start() {
        guard !started else {
            flushPendingMoments()
            return
        }
        started = true

        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.flushPendingMoments()
        }

        flushPendingMoments()
    }

    /// Retry every local capture that has not yet been positively acknowledged by
    /// the iPhone. Existing outstanding transferUserInfo payloads are detected so
    /// repeated foreground wakes do not flood WatchConnectivity with duplicates.
    func flushPendingMoments() {
        let session = WCSession.default
        guard session.activationState == .activated else {
            logger.debug("Capture sync waiting for WCSession activation")
            return
        }

        guard session.isCompanionAppInstalled else {
            logger.warning("Capture sync blocked: companion iPhone app is not reported installed")
            return
        }

        guard let moments = loadMoments(), !moments.isEmpty else { return }

        let outstandingIds = Set(session.outstandingUserInfoTransfers.compactMap {
            $0.userInfo["id"] as? String
        })

        for moment in moments {
            let id = moment.id.uuidString
            guard !deliveredIds.contains(id),
                  !inFlightIds.contains(id),
                  !outstandingIds.contains(id) else { continue }
            send(moment, via: session)
        }
    }

    private func send(_ moment: CapturedMoment, via session: WCSession) {
        let id = moment.id.uuidString
        inFlightIds.insert(id)
        let payload = payload(for: moment)

        if session.isReachable {
            session.sendMessage(payload, replyHandler: { [weak self] reply in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.inFlightIds.remove(id)
                    if (reply["status"] as? String) == "ok" {
                        self.markDelivered(id)
                    } else {
                        self.queueDurable(payload, id: id, via: session)
                    }
                }
            }, errorHandler: { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.logger.error("Live captured-moment send failed: \(error.localizedDescription); queueing durable transfer")
                    self.inFlightIds.remove(id)
                    self.queueDurable(payload, id: id, via: session)
                }
            })
        } else {
            inFlightIds.remove(id)
            queueDurable(payload, id: id, via: session)
        }
    }

    private func queueDurable(_ payload: [String: Any], id: String, via session: WCSession) {
        let alreadyQueued = session.outstandingUserInfoTransfers.contains {
            ($0.userInfo["id"] as? String) == id
        }
        guard !alreadyQueued else { return }

        _ = session.transferUserInfo(payload)
        logger.info("Queued durable captured-moment transfer: \(id)")
        // Deliberately DO NOT mark delivered here. transferUserInfo being queued is
        // not proof that the iPhone has stored it. A future live ack will retire it.
    }

    private func markDelivered(_ id: String) {
        guard deliveredIds.insert(id).inserted else { return }
        UserDefaults.standard.set(Array(deliveredIds), forKey: deliveredKey)
        logger.info("iPhone acknowledged captured moment: \(id)")
    }

    private func payload(for moment: CapturedMoment) -> [String: Any] {
        [
            "command": "captured_moment",
            "id": moment.id.uuidString,
            "episodeId": moment.episodeId,
            "podcastTitle": moment.podcastTitle,
            "episodeTitle": moment.episodeTitle,
            "timestampSec": moment.timestampSec,
            "capturedAt": moment.capturedAt.timeIntervalSince1970,
        ]
    }

    private func loadMoments() -> [CapturedMoment]? {
        guard let data = UserDefaults.standard.data(forKey: momentsKey) else { return nil }
        return try? JSONDecoder().decode([CapturedMoment].self, from: data)
    }

    // MARK: - Prototype diagnostics

    var localMomentCount: Int { loadMoments()?.count ?? 0 }
    var deliveredMomentCount: Int { deliveredIds.count }

    var pendingMomentCount: Int {
        guard let moments = loadMoments() else { return 0 }
        return moments.filter { !deliveredIds.contains($0.id.uuidString) }.count
    }

    /// Clears only the delivery acknowledgements, never the actual captured moments.
    /// Useful while iterating on WatchConnectivity: every local marker will retry.
    func retryAllLocalMoments() {
        deliveredIds.removeAll()
        UserDefaults.standard.removeObject(forKey: deliveredKey)
        flushPendingMoments()
    }
}
