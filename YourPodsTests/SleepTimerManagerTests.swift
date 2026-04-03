import XCTest
@testable import YourPods

/// Extended tests for SleepTimerManager — supplements the basic tests in YourPodsTests.swift
/// with callback behavior, edge cases, and multi-start scenarios.
final class SleepTimerExtendedTests: XCTestCase {
    
    // MARK: - Formatted Remaining Edge Cases
    
    func test_formattedRemaining_zero() {
        let timer = SleepTimerManager()
        timer.remainingSeconds = 0
        XCTAssertEqual(timer.formattedRemaining, "0:00")
    }
    
    func test_formattedRemaining_singleDigitSeconds() {
        let timer = SleepTimerManager()
        timer.remainingSeconds = 5
        XCTAssertEqual(timer.formattedRemaining, "0:05")
    }
    
    func test_formattedRemaining_exactMinute() {
        let timer = SleepTimerManager()
        timer.remainingSeconds = 60
        XCTAssertEqual(timer.formattedRemaining, "1:00")
    }
    
    func test_formattedRemaining_largeValue() {
        let timer = SleepTimerManager()
        timer.remainingSeconds = 3661 // 61 min 1 sec
        XCTAssertEqual(timer.formattedRemaining, "61:01")
    }
    
    // MARK: - Timer Callback
    
    func test_onTimerExpired_callbackFires() {
        let timer = SleepTimerManager()
        var callbackFired = false
        timer.onTimerExpired = { callbackFired = true }
        
        // Start a minimal timer and set remaining to simulate near-expiry
        timer.start(minutes: 1)
        timer.remainingSeconds = 1
        
        let expectation = XCTestExpectation(description: "Timer expired callback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)
        
        XCTAssertTrue(callbackFired, "onTimerExpired should fire when timer reaches 0")
        XCTAssertFalse(timer.isActive, "Timer should be inactive after expiry")
    }
    
    func test_stop_preventsCallbackFromFiring() {
        let timer = SleepTimerManager()
        var callbackFired = false
        timer.onTimerExpired = { callbackFired = true }
        
        timer.start(minutes: 1)
        timer.remainingSeconds = 2
        
        // Stop before it expires
        timer.stop()
        
        let expectation = XCTestExpectation(description: "Wait for potential callback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 4.0)
        
        XCTAssertFalse(callbackFired, "Callback should NOT fire after stop()")
    }
    
    // MARK: - Multiple Starts
    
    func test_consecutiveStarts_firstTimerCancelled() {
        let timer = SleepTimerManager()
        var callbackCount = 0
        timer.onTimerExpired = { callbackCount += 1 }
        
        // Start and immediately override
        timer.start(minutes: 1)
        timer.remainingSeconds = 1
        timer.start(minutes: 15) // Override — first timer should be cancelled
        
        let expectation = XCTestExpectation(description: "Wait for potential double fire")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 4.0)
        
        XCTAssertEqual(callbackCount, 0,
                       "First timer's callback should not fire after being overridden")
        XCTAssertTrue(timer.isActive, "Second timer should still be active")
        timer.stop()
    }
    
    // MARK: - Extend Edge Case
    
    func test_extend_largeAmount() {
        let timer = SleepTimerManager()
        timer.start(minutes: 5)
        timer.extend(minutes: 120)
        
        XCTAssertEqual(timer.remainingSeconds, 7500, "5 + 120 minutes = 7500 seconds")
        XCTAssertEqual(timer.selectedMinutes, 125)
        
        timer.stop()
    }
}
