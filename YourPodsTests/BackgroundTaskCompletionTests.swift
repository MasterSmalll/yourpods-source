import XCTest
@testable import YourPods

/// Tests for the BGTask deterministic completion mechanism .
///
/// The idempotent completer ensures that `setTaskCompleted` is called
/// exactly once per task — even when the expiration handler races
/// against the normal completion path.
final class BackgroundTaskCompletionTests: XCTestCase {
    
    // MARK: - BGTaskCompleter
    
    /// The completer must call the completion handler exactly once.
    func test_completer_callsCompletionExactlyOnce() {
        var callCount = 0
        let completer = BGTaskCompleter { _ in
            callCount += 1
        }
        
        completer.complete(success: true)
        completer.complete(success: true) // second call should be no-op
        completer.complete(success: false) // third call should be no-op
        
        XCTAssertEqual(callCount, 1,
                       "Completer must call completion exactly once, was called \(callCount) times")
    }
    
    /// First call determines the success value.
    func test_completer_firstCallDeterminesSuccess() {
        var successValue: Bool?
        let completer = BGTaskCompleter { success in
            successValue = success
        }
        
        completer.complete(success: false)
        completer.complete(success: true) // ignored
        
        XCTAssertEqual(successValue, false,
                       "First call's success value must be the one used")
    }
    
    /// Thread safety: concurrent calls from expiration handler and normal path.
    func test_completer_threadSafe() {
        var callCount = 0
        let lock = NSLock()
        let completer = BGTaskCompleter { _ in
            lock.lock()
            callCount += 1
            lock.unlock()
        }
        
        let group = DispatchGroup()
        for _ in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                completer.complete(success: true)
                group.leave()
            }
        }
        group.wait()
        
        XCTAssertEqual(callCount, 1,
                       "Completer must be thread-safe — exactly 1 call from 100 concurrent attempts")
    }
}
