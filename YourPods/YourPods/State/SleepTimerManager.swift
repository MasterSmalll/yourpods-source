import Foundation
import os

/// Manages a countdown sleep timer that pauses playback when it expires.
@Observable
final class SleepTimerManager {
    private let logger = Logger(subsystem: "com.yourpods", category: "SleepTimerManager")
    
    /// Whether the timer is currently running.
    var isActive: Bool = false
    
    /// Remaining seconds on the timer.
    var remainingSeconds: Int = 0
    
    /// The originally selected duration in minutes.
    var selectedMinutes: Int = 0
    
    /// When true, playback will stop at the end of the current episode
    /// instead of auto-advancing to the next one.
    var stopAfterCurrentEpisode: Bool = false
    
    /// Preset durations offered to the user.
    static let presets: [Int] = [5, 15, 30, 60]
    
    /// Callback to pause playback when the timer expires.
    var onTimerExpired: (() -> Void)?
    
    private var timer: Timer?
    
    // MARK: - Controls
    
    /// Start a countdown for the given number of minutes.
    func start(minutes: Int) {
        stop()
        selectedMinutes = minutes
        remainingSeconds = minutes * 60
        isActive = true
        
        logger.info("Sleep timer started: \(minutes) minutes")
        
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            
            if self.remainingSeconds <= 1 {
                self.logger.info("Sleep timer expired — pausing playback")
                self.onTimerExpired?()
                self.stop()
            } else {
                self.remainingSeconds -= 1
            }
        }
    }
    
    /// Stop and reset the timer (including end-of-episode mode).
    func stop() {
        timer?.invalidate()
        timer = nil
        isActive = false
        remainingSeconds = 0
        selectedMinutes = 0
        stopAfterCurrentEpisode = false
    }
    
    /// Extend the active timer by additional minutes.
    func extend(minutes: Int) {
        guard isActive else { return }
        remainingSeconds += minutes * 60
        selectedMinutes += minutes
        logger.info("Sleep timer extended by \(minutes) minutes, \(self.remainingSeconds)s remaining")
    }
    
    /// Activate "End of Episode" mode — playback stops when the current episode finishes.
    func startEndOfEpisode() {
        stop() // Cancel any running countdown timer
        stopAfterCurrentEpisode = true
        logger.info("Sleep timer: end-of-episode mode activated")
    }
    
    /// Cancel "End of Episode" mode.
    func cancelEndOfEpisode() {
        stopAfterCurrentEpisode = false
        logger.info("Sleep timer: end-of-episode mode cancelled")
    }
    
    /// Formatted remaining time string (e.g. "14:32").
    var formattedRemaining: String {
        let m = remainingSeconds / 60
        let s = remainingSeconds % 60
        return String(format: "%d:%02d", m, s)
    }
    
    deinit {
        timer?.invalidate()
    }
}
