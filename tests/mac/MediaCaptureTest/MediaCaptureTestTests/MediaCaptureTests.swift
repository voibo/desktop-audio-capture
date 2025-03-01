import XCTest
import AVFoundation
import ScreenCaptureKit
@testable import MediaCaptureTest

/// MediaCapture tests - Configured with environment variables in Test Plans.
final class MediaCaptureTests: XCTestCase {
    
    var mediaCapture: MediaCapture!
    
    /// Creates the appropriate MediaCapture instance based on the environment variable.
    override func setUpWithError() throws {
        try super.setUpWithError()
        // Use MockMediaCapture if the USE_MOCK_CAPTURE environment variable is set.
        // This allows switching test environments using XCTestPlan.
        if ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] == "1" {
            mediaCapture = MockMediaCapture()
            print("Testing MediaCapture in mock mode.")
        } else {
            mediaCapture = MediaCapture()
            print("Testing MediaCapture in real environment.")
        }
    }
    
    override func tearDownWithError() throws {
        if mediaCapture.isCapturing() {
            mediaCapture.stopCaptureSync()
        }
        mediaCapture = nil
        try super.tearDownWithError()
    }
    
    // MARK: - Basic Functionality Tests
    
    func testAvailableTargets() async throws {
        // Get available windows and displays.
        let targets = try await MediaCapture.availableCaptureTargets(ofType: .all)
        
        // There should be at least one target available.
        XCTAssertFalse(targets.isEmpty, "No available capture targets.")
        
        // Verify target information.
        for target in targets {
            if target.isDisplay {
                XCTAssertGreaterThan(target.displayID, 0, "Invalid display ID.")
                XCTAssertFalse(target.frame.isEmpty, "Invalid display frame.")
            } else if target.isWindow {
                XCTAssertGreaterThan(target.windowID, 0, "Invalid window ID.")
                XCTAssertNotNil(target.title, "Window title should not be nil.")
            }
        }
    }
    
    func testStartAndStopCapture() async throws {
        // Get available targets.
        let targets = try await MediaCapture.availableCaptureTargets(ofType: .all)
        guard !targets.isEmpty else {
            XCTFail("No capture targets available for testing.")
            return
        }
        
        // Use the first available target.
        let target = targets[0]
        
        // Expect to receive media data.
        let expectation = expectation(description: "Received media data.")
        var receivedData = false
        
        // Start capturing.
        let success = try await mediaCapture.startCapture(
            target: target,
            mediaHandler: { media in
                if !receivedData {
                    receivedData = true
                    expectation.fulfill()
                }
            }
        )
        
        // Check if capture started successfully.
        XCTAssertTrue(success, "Capture should start successfully.")
        XCTAssertTrue(mediaCapture.isCapturing(), "isCapturing should return true.")
        
        // Wait for data to be received.
        await fulfillment(of: [expectation], timeout: 5.0)
        XCTAssertTrue(receivedData, "Should have received media data.")
        
        // Stop capturing.
        await mediaCapture.stopCapture()
        XCTAssertFalse(mediaCapture.isCapturing(), "isCapturing should return false.")
    }
    
    func testSyncStopCapture() async throws {
        // Get available targets.
        let targets = try await MediaCapture.availableCaptureTargets(ofType: .all)
        guard !targets.isEmpty else {
            XCTFail("No capture targets available for testing.")
            return
        }
        
        let target = targets[0]
        
        // Start capturing.
        _ = try await mediaCapture.startCapture(
            target: target,
            mediaHandler: { _ in }
        )
        
        XCTAssertTrue(mediaCapture.isCapturing(), "Capture should be started.")
        
        // Stop synchronously.
        mediaCapture.stopCaptureSync()
        XCTAssertFalse(mediaCapture.isCapturing(), "isCapturing should return false after synchronous stop.")
    }
    
    // MARK: - Media Data Verification Tests
    
    func testMediaDataFormat() async throws {
        // Get available targets.
        let targets = try await MediaCapture.availableCaptureTargets(ofType: .all)
        guard !targets.isEmpty else {
            XCTFail("No capture targets available for testing.")
            return
        }
        
        let target = targets[0]
        
        // Expect valid media data.
        let expectation = expectation(description: "Received valid media data.")
        
        // Start capturing.
        _ = try await mediaCapture.startCapture(
            target: target,
            mediaHandler: { media in
                // Check metadata.
                XCTAssertGreaterThan(media.metadata.timestamp, 0, "Timestamp should be a positive value.")
                
                if let videoBuffer = media.videoBuffer, let videoInfo = media.metadata.videoInfo {
                    XCTAssertGreaterThan(videoInfo.width, 0, "Width should be a positive value.")
                    XCTAssertGreaterThan(videoInfo.height, 0, "Height should be a positive value.")
                    XCTAssertGreaterThan(videoInfo.bytesPerRow, 0, "Bytes per row should be a positive value.")
                    XCTAssertGreaterThan(videoBuffer.count, 0, "Video buffer should not be empty.")
                }
                
                if let audioBuffer = media.audioBuffer, let audioInfo = media.metadata.audioInfo {
                    XCTAssertGreaterThan(audioInfo.sampleRate, 0, "Sample rate should be a positive value.")
                    XCTAssertGreaterThanOrEqual(audioInfo.channelCount, 1, "Channel count should be at least 1.")
                    XCTAssertGreaterThan(audioBuffer.count, 0, "Audio buffer should not be empty.")
                }
                
                expectation.fulfill()
            }
        )
        
        // Wait for data to be received.
        await fulfillment(of: [expectation], timeout: 5.0)
        
        // Stop capturing.
        await mediaCapture.stopCapture()
    }
    
    // MARK: - Error Handling Tests
    
    func testErrorHandling() async throws {
        // Attempt to capture with an invalid window ID.
        let invalidTarget = MediaCaptureTarget(windowID: 99999, title: "Non-existent Window")
        
        // Expect an error to occur.
        let expectation = expectation(description: "An error should occur.")
        var expectationFulfilled = false
        
        do {
            _ = try await mediaCapture.startCapture(
                target: invalidTarget,
                mediaHandler: { _ in },
                errorHandler: { _ in
                    // In mock mode, the error handler should be called.
                    if ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] == "1" && !expectationFulfilled {
                        expectationFulfilled = true
                        expectation.fulfill()
                    }
                }
            )
            // In mock mode, an error should be thrown, but in a real environment, it may not fail with an invalid ID.
            if ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] == "1" {
                XCTFail("An error should be thrown in mock mode.")
            }
        } catch {
            // Success if an error is thrown.
            if !expectationFulfilled {
                expectationFulfilled = true
                expectation.fulfill()
            }
        }
        
        // Wait for the error handling to complete.
        await fulfillment(of: [expectation], timeout: 3.0)
        
        // Verify that capture has not started.
        XCTAssertFalse(mediaCapture.isCapturing(), "Capture should not be started after an error.")
    }
    
    // MARK: - Configuration Tests
    
    func testDifferentQualitySettings() async throws {
        // Verify that capture can be started with different quality settings.
        let qualities: [MediaCapture.CaptureQuality] = [.high, .medium, .low]
        let targets = try await MediaCapture.availableCaptureTargets(ofType: .all)
        guard !targets.isEmpty else {
            XCTFail("No capture targets available for testing.")
            return
        }
        
        let target = targets[0]
        
        for quality in qualities {
            // Start capturing.
            let expectation = expectation(description: "Capture with \(quality) quality.")
            
            _ = try await mediaCapture.startCapture(
                target: target,
                mediaHandler: { _ in
                    expectation.fulfill()
                },
                quality: quality
            )
            
            // Wait for data to be received.
            await fulfillment(of: [expectation], timeout: 3.0)
            
            // Stop capturing.
            await mediaCapture.stopCapture()
            
            // Wait briefly before the next test.
            try await Task.sleep(for: .milliseconds(500))
        }
    }
    
    // MARK: - Frame Rate Tests
    
    func testDifferentFrameRates() async throws {
        // Verify that capture can be started with different frame rates.
        let frameRates: [Double] = [30.0, 15.0, 5.0]
        let targets = try await MediaCapture.availableCaptureTargets(ofType: .all)
        guard !targets.isEmpty else {
            XCTFail("No capture targets available for testing.")
            return
        }
        
        let target = targets[0]
        
        for fps in frameRates {
            // Start capturing.
            let expectation = expectation(description: "Capture with \(fps) fps.")
            
            _ = try await mediaCapture.startCapture(
                target: target,
                mediaHandler: { _ in
                    expectation.fulfill()
                },
                framesPerSecond: fps
            )
            
            // Wait for data to be received.
            await fulfillment(of: [expectation], timeout: 3.0)
            
            // Stop capturing.
            await mediaCapture.stopCapture()
            
            // Wait briefly before the next test.
            try await Task.sleep(for: .milliseconds(500))
        }
    }
    
    // MARK: - Media Type Tests
    
    func testAudioOnlyCapture() async throws {
        // Test audio-only capture with a frame rate of 0.
        let targets = try await MediaCapture.availableCaptureTargets(ofType: .all)
        guard !targets.isEmpty else {
            XCTFail("No capture targets available for testing.")
            return
        }
        
        let target = targets[0]
        let expectation = expectation(description: "Received audio data.")
        var receivedAudioData = false
        var receivedVideoData = false
        
        _ = try await mediaCapture.startCapture(
            target: target,
            mediaHandler: { media in
                if media.audioBuffer != nil {
                    receivedAudioData = true
                }
                if media.videoBuffer != nil {
                    receivedVideoData = true
                }
                
                // Success if audio data is received.
                if receivedAudioData {
                    expectation.fulfill()
                }
            },
            framesPerSecond: 0.0 // Frame rate 0 means audio-only mode.
        )
        
        // Wait for data to be received.
        await fulfillment(of: [expectation], timeout: 5.0)
        
        // Stop capturing.
        await mediaCapture.stopCapture()
        
        // Should have audio but no video (both may be present in mock mode).
        XCTAssertTrue(receivedAudioData, "Should have received audio data.")
        if ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] != "1" {
            // Only verify in a real environment (both may be present in mock mode).
            XCTAssertFalse(receivedVideoData, "Should not have received video data.")
        }
    }
    
    // MARK: - Target Information Tests
    
    func testTargetProperties() async throws {
        // Verify detailed target information.
        let targets = try await MediaCapture.availableCaptureTargets(ofType: .all)
        guard !targets.isEmpty else {
            XCTFail("No capture targets available.")
            return
        }
        
        // Verify windows and displays.
        let windows = targets.filter { $0.isWindow }
        let displays = targets.filter { $0.isDisplay }
        
        // Verify window information.
        for window in windows {
            XCTAssertTrue(window.isWindow, "isWindow should return true.")
            XCTAssertFalse(window.isDisplay, "isDisplay should return false.")
            XCTAssertGreaterThan(window.windowID, 0, "Valid window ID.")
            
            // Window should have a title or related information.
            if let title = window.title {
                XCTAssertFalse(title.isEmpty, "Window title should not be empty.")
            }
            
            // Verify that the frame is not zero.
            XCTAssertFalse(window.frame.isEmpty, "Window frame should not be empty.")
        }
        
        // Verify display information.
        for display in displays {
            XCTAssertTrue(display.isDisplay, "isDisplay should return true.")
            XCTAssertFalse(display.isWindow, "isWindow should return false.")
            XCTAssertGreaterThan(display.displayID, 0, "Valid display ID.")
            XCTAssertFalse(display.frame.isEmpty, "Display frame should not be empty.")
        }
    }
    
    // MARK: - Resource Management Tests
    
    func testMultipleStartStopCycles() async throws {
        // Test stability with multiple capture start/stop cycles.
        let targets = try await MediaCapture.availableCaptureTargets(ofType: .all)
        guard !targets.isEmpty else {
            XCTFail("No capture targets available for testing.")
            return
        }
        
        let target = targets[0]
        
        // Repeat capture start/stop multiple times.
        for i in 1...3 {
            print("Capture cycle \(i)/3")
            
            let expectation = expectation(description: "Capture cycle \(i)")
            
            // Start capturing.
            _ = try await mediaCapture.startCapture(
                target: target,
                mediaHandler: { _ in
                    expectation.fulfill()
                }
            )
            
            // Wait for data to be received.
            await fulfillment(of: [expectation], timeout: 3.0)
            
            // Stop capturing.
            await mediaCapture.stopCapture()
            
            // Wait briefly before the next cycle.
            try await Task.sleep(for: .milliseconds(500))
        }
        
        // After all cycles are complete, verify that the capture state is set correctly.
        XCTAssertFalse(mediaCapture.isCapturing(), "Capture should be stopped at the end.")
    }
    
    // MARK: - Bundle ID Target Tests

    func testBundleIDTargetCapture() async throws {
        // Test capture using bundleID targeting
        // This test verifies that we can target an app by its bundle identifier
        
        // Skip this test if in mock mode as it's targeting real apps
        guard ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] != "1" else {
            print("Skipping bundle ID test in mock mode")
            return
        }
        
        // Create a target with a known bundleID (Finder is guaranteed to exist on macOS)
        let finderBundleID = "com.apple.finder"
        let bundleTarget = MediaCaptureTarget(bundleID: finderBundleID)
        
        // Expect to receive media data
        let expectation = expectation(description: "Received media data from app with specified bundle ID")
        var receivedData = false
        
        // Start capture with the bundle target
        do {
            let success = try await mediaCapture.startCapture(
                target: bundleTarget,
                mediaHandler: { media in
                    if !receivedData {
                        receivedData = true
                        expectation.fulfill()
                    }
                }
            )
            
            // Check if capture started successfully
            XCTAssertTrue(success, "Capture should start successfully with bundle ID targeting")
            
            // Wait for data to be received
            await fulfillment(of: [expectation], timeout: 5.0)
            XCTAssertTrue(receivedData, "Should have received media data from targeted app")
            
            // Stop capturing
            await mediaCapture.stopCapture()
        } catch {
            // Finder might not be visible, so failure is acceptable
            print("Could not capture app with bundle ID: \(error.localizedDescription)")
        }
    }

    // MARK: - Edge Case Tests

    func testExtremeFameRates() async throws {
        // Test capture with extreme frame rates (very low and very high)
        let frameRates: [Double] = [0.1, 120.0]
        let targets = try await MediaCapture.availableCaptureTargets(ofType: .all)
        guard !targets.isEmpty else {
            XCTFail("No capture targets available for testing")
            return
        }
        
        let target = targets[0]
        
        for fps in frameRates {
            // Start capturing
            let expectation = expectation(description: "Capture with extreme frame rate: \(fps) fps")
            
            _ = try await mediaCapture.startCapture(
                target: target,
                mediaHandler: { _ in
                    expectation.fulfill()
                },
                framesPerSecond: fps
            )
            
            // Use longer timeout for very low frame rates
            let timeout = fps < 1.0 ? 15.0 : 5.0
            await fulfillment(of: [expectation], timeout: timeout)
            
            // Stop capturing
            await mediaCapture.stopCapture()
            
            // Wait briefly before the next test
            try await Task.sleep(for: .milliseconds(800))
        }
    }

    // MARK: - Recovery Tests

    func testRecoveryFromError() async throws {
        // Test that capture can be restarted after an error condition
        let targets = try await MediaCapture.availableCaptureTargets(ofType: .all)
        guard !targets.isEmpty else {
            XCTFail("No capture targets available for testing")
            return
        }
        
        let validTarget = targets[0]
        let invalidTarget = MediaCaptureTarget(windowID: 99999, title: "Non-existent Window")
        
        // First attempt with invalid target (expected to fail)
        do {
            _ = try await mediaCapture.startCapture(
                target: invalidTarget,
                mediaHandler: { _ in }
            )
            
            if ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] == "1" {
                XCTFail("Capture with invalid target should fail in mock mode")
            }
        } catch {
            // Expected error
            print("Expected error occurred: \(error.localizedDescription)")
        }
        
        // Verify capture is not active
        XCTAssertFalse(mediaCapture.isCapturing(), "Capture should not be active after error")
        
        // Now try with valid target (should succeed)
        let expectation = expectation(description: "Successful capture after recovery from error")
        
        let success = try await mediaCapture.startCapture(
            target: validTarget,
            mediaHandler: { _ in
                expectation.fulfill()
            }
        )
        
        // Check if second capture started successfully
        XCTAssertTrue(success, "Capture should start successfully after recovery")
        XCTAssertTrue(mediaCapture.isCapturing(), "isCapturing should return true after recovery")
        
        // Wait for data
        await fulfillment(of: [expectation], timeout: 5.0)
        
        // Stop capturing
        await mediaCapture.stopCapture()
    }

    // MARK: - Performance Tests

    func testExtendedCapture() async throws {
        // Test stability during longer capture sessions
        // This test ensures the capture process doesn't degrade over time
        
        let targets = try await MediaCapture.availableCaptureTargets(ofType: .all)
        guard !targets.isEmpty else {
            XCTFail("No capture targets available for testing")
            return
        }
        
        let target = targets[0]
        let captureDuration = 10.0 // 10 seconds (adjust as needed)
        
        // Extended capture with frame counting
        let expectation = expectation(description: "Extended capture completed")
        var frameCount = 0
        var lastFrameTime: TimeInterval = 0
        var firstFrameTime: TimeInterval = 0
        
        // Start capturing
        _ = try await mediaCapture.startCapture(
            target: target,
            mediaHandler: { media in
                let currentTime = Date().timeIntervalSince1970
                
                // Record time of first frame
                if frameCount == 0 {
                    firstFrameTime = currentTime
                }
                
                frameCount += 1
                lastFrameTime = currentTime
            }
        )
        
        // Run the capture for the specified duration
        try await Task.sleep(for: .seconds(captureDuration))
        
        // Stop capturing
        await mediaCapture.stopCapture()
        expectation.fulfill()
        
        await fulfillment(of: [expectation], timeout: 1.0)
        
        // Capture metrics
        let totalDuration = lastFrameTime - firstFrameTime
        let averageFps = Double(frameCount) / totalDuration
        
        // Print metrics but don't assert (as performance varies by environment)
        print("Extended capture metrics:")
        print("  Duration: \(totalDuration) seconds")
        print("  Frames captured: \(frameCount)")
        print("  Average FPS: \(averageFps)")
        
        // Basic verification that capture worked
        XCTAssertGreaterThan(frameCount, 0, "Should have captured at least one frame")
        
        // Only verify FPS in mock mode where we have predictable behavior
        if ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] == "1" {
            XCTAssertGreaterThan(averageFps, 1.0, "Frame rate should be reasonable")
        }
    }

    // MARK: - Configuration Boundary Tests

    func testZeroFrameRateWithVideo() async throws {
        // Test special case: zero frame rate but explicit video request
        let targets = try await MediaCapture.availableCaptureTargets(ofType: .all)
        guard !targets.isEmpty else {
            XCTFail("No capture targets available for testing")
            return
        }
        
        let target = targets[0]
        let expectation = expectation(description: "Zero frame rate capture completed")
        var receivedVideo = false
        var receivedAudio = false
        
        // Create a custom quality to force video processing
        let customQuality = MediaCapture.CaptureQuality.low
        
        // Start capturing with zero frame rate but explicit video quality
        _ = try await mediaCapture.startCapture(
            target: target,
            mediaHandler: { media in
                if media.videoBuffer != nil {
                    receivedVideo = true
                }
                if media.audioBuffer != nil {
                    receivedAudio = true
                }
                
                if receivedAudio || receivedVideo {
                    expectation.fulfill()
                }
            },
            framesPerSecond: 0.0,
            quality: customQuality
        )
        
        // Wait for data
        await fulfillment(of: [expectation], timeout: 5.0)
        
        // Stop capturing
        await mediaCapture.stopCapture()
        
        // In real environment, we expect only audio with zero frame rate
        // In mock mode, both might come through
        XCTAssertTrue(receivedAudio, "Should have received audio data")
        
        if ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] != "1" {
            XCTAssertFalse(receivedVideo, "Should not have received video data with zero frame rate")
        }
    }

    // Add test cases

    // MARK: - Target Type Tests

    func testScreenOnlyTargets() async throws {
        // Test retrieving screen-only targets
        let screenTargets = try await MediaCapture.availableCaptureTargets(ofType: .screen)
        
        // There should be at least one screen available
        XCTAssertFalse(screenTargets.isEmpty, "No available screen targets")
        
        // Verify that all elements are screens
        for target in screenTargets {
            XCTAssertTrue(target.isDisplay, "Target should be a display")
            XCTAssertFalse(target.isWindow, "Target should not be a window")
            XCTAssertGreaterThan(target.displayID, 0, "Display ID should be valid")
        }
        
        // Test capturing from a screen target
        if let screenTarget = screenTargets.first {
            let expectation = expectation(description: "Capture from display")
            var receivedData = false
            
            _ = try await mediaCapture.startCapture(
                target: screenTarget,
                mediaHandler: { media in
                    // Test succeeds if capture data is received
                    if !receivedData {
                        receivedData = true
                        expectation.fulfill()
                    }
                }
            )
            
            await fulfillment(of: [expectation], timeout: 5.0)
            XCTAssertTrue(receivedData, "Should have received media data from screen")
            
            await mediaCapture.stopCapture()
        }
    }

    func testWindowOnlyTargets() async throws {
        // Test retrieving window-only targets
        let windowTargets = try await MediaCapture.availableCaptureTargets(ofType: .window)
        
        // Some test environments might not have windows available
        if !windowTargets.isEmpty {
            // Verify that all elements are windows
            for target in windowTargets {
                XCTAssertTrue(target.isWindow, "Target should be a window")
                XCTAssertFalse(target.isDisplay, "Target should not be a display")
                XCTAssertGreaterThan(target.windowID, 0, "Window ID should be valid")
            }
            
            // Test capturing from a window target (if available in the test environment)
            if let windowTarget = windowTargets.first {
                let expectation = expectation(description: "Capture from window")
                var receivedData = false
                
                do {
                    _ = try await mediaCapture.startCapture(
                        target: windowTarget,
                        mediaHandler: { media in
                            if !receivedData {
                                receivedData = true
                                expectation.fulfill()
                            }
                        }
                    )
                    
                    await fulfillment(of: [expectation], timeout: 5.0)
                    XCTAssertTrue(receivedData, "Should have received media data from window")
                    
                    await mediaCapture.stopCapture()
                } catch {
                    // Window capture might fail (e.g., hidden windows)
                    print("Window capture test skipped: \(error.localizedDescription)")
                }
            }
        } else {
            print("No windows available for testing")
        }
    }

    func testTargetTypeSeparation() async throws {
        // Retrieve all targets, screen-only, and window-only targets and compare
        let allTargets = try await MediaCapture.availableCaptureTargets(ofType: .all)
        let screenTargets = try await MediaCapture.availableCaptureTargets(ofType: .screen)
        let windowTargets = try await MediaCapture.availableCaptureTargets(ofType: .window)
        
        // Verify that the legacy method returns the same results as .all
        let legacyTargets = try await MediaCapture.availableCaptureTargets()
        XCTAssertEqual(allTargets.count, legacyTargets.count, "Legacy method should return the same count as .all")
        
        // Verify that the sum of screen and window targets equals the total number of targets
        XCTAssertEqual(allTargets.count, screenTargets.count + windowTargets.count, 
                       "Sum of screen and window targets should equal all targets")
        
        // Verify that screen targets do not include windows
        for target in screenTargets {
            XCTAssertTrue(target.isDisplay, "Screen target should be a display")
        }
        
        // Verify that window targets do not include screens
        for target in windowTargets {
            XCTAssertTrue(target.isWindow, "Window target should be a window")
        }
    }

    func testTargetSelectionCompatibility() async throws {
        // Test compatibility with legacy code
        // Verify that capturing works the same with targets retrieved using the new and old methods
        
        // Retrieve screen targets (new method)
        let screenTargets = try await MediaCapture.availableCaptureTargets(ofType: .screen)
        
        guard let screenTarget = screenTargets.first else {
            print("No screen targets available for compatibility test")
            return
        }
        
        // Find the same screen in the targets retrieved using the legacy method
        let legacyTargets = try await MediaCapture.availableCaptureTargets(ofType: .all)
        let matchingLegacyTarget = legacyTargets.first { $0.displayID == screenTarget.displayID }
        
        guard let legacyTarget = matchingLegacyTarget else {
            XCTFail("Could not find matching target in legacy method results")
            return
        }
        
        // Verify that capturing works with both targets
        let expectation1 = expectation(description: "Capture with new method")
        var receivedData1 = false
        
        _ = try await mediaCapture.startCapture(
            target: screenTarget,
            mediaHandler: { _ in
                if !receivedData1 {
                    receivedData1 = true
                    expectation1.fulfill()
                }
            }
        )
        
        await fulfillment(of: [expectation1], timeout: 5.0)
        await mediaCapture.stopCapture()
        
        // Wait briefly to ensure capture has fully stopped
        try await Task.sleep(for: .milliseconds(500))
        
        // Test with the legacy target
        let expectation2 = expectation(description: "Capture with legacy method")
        var receivedData2 = false
        
        _ = try await mediaCapture.startCapture(
            target: legacyTarget,
            mediaHandler: { _ in
                if !receivedData2 {
                    receivedData2 = true
                    expectation2.fulfill()
                }
            }
        )
        
        await fulfillment(of: [expectation2], timeout: 5.0)
        await mediaCapture.stopCapture()
        
        XCTAssertTrue(receivedData1, "Should receive data with new target method")
        XCTAssertTrue(receivedData2, "Should receive data with legacy target method")
    }

    // Additional test cases for availableCaptureTargets

    // MARK: - Advanced Target Tests

    func testMockModeTargets() async throws {
        // Verify that mock mode returns the correct results
        let isMockMode = ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] == "1"
        
        // Retrieve various target types
        let screens = try await MediaCapture.availableCaptureTargets(ofType: .screen)
        let windows = try await MediaCapture.availableCaptureTargets(ofType: .window)
        let all = try await MediaCapture.availableCaptureTargets(ofType: .all)
        
        // Verify that mock mode returns a fixed number of targets
        if isMockMode {
            XCTAssertEqual(screens.count, 1, "Mock mode should return exactly 1 screen")
            XCTAssertEqual(windows.count, 2, "Mock mode should return exactly 2 windows")
            XCTAssertEqual(all.count, 3, "Mock mode should return exactly 3 targets in total")
            
            // Verify mock target properties
            XCTAssertEqual(screens[0].displayID, 1, "Mock screen should have displayID=1")
            XCTAssertEqual(windows[0].windowID, 1, "First mock window should have windowID=1")
            XCTAssertEqual(windows[1].windowID, 2, "Second mock window should have windowID=2")
        } else {
            // Verify that there are at least the minimum required targets in a real environment
            XCTAssertGreaterThanOrEqual(screens.count, 1, "At least one screen should be available")
            XCTAssertEqual(all.count, screens.count + windows.count, "Total targets should equal screens + windows")
        }
    }

    func testConcurrentTargetRequests() async throws {
        // Verify that multiple concurrent requests work correctly
        async let screens1 = MediaCapture.availableCaptureTargets(ofType: .screen)
        async let screens2 = MediaCapture.availableCaptureTargets(ofType: .screen)
        async let windows = MediaCapture.availableCaptureTargets(ofType: .window)
        async let all = MediaCapture.availableCaptureTargets(ofType: .all)
        
        // Wait for all results
        let (screensResult1, screensResult2, windowsResult, allResult) = try await (screens1, screens2, windows, all)
        
        // Identical requests should return the same results
        XCTAssertEqual(screensResult1.count, screensResult2.count, "Concurrent identical requests should return same count")
        
        // Total targets should equal screens + windows
        XCTAssertEqual(allResult.count, screensResult1.count + windowsResult.count, "Total targets should equal screens + windows")
    }

    func testPerformanceOfTargetRetrieval() async throws {
        // Measure the performance of target retrieval
        measure {
            let expectation = self.expectation(description: "Target retrieval completed")
            
            Task {
                do {
                    _ = try await MediaCapture.availableCaptureTargets(ofType: .all)
                    expectation.fulfill()
                } catch {
                    XCTFail("Target retrieval failed: \(error.localizedDescription)")
                }
            }
            
            wait(for: [expectation], timeout: 5.0)
        }
    }

    func testCaptureTargetEquality() async throws {
        // Verify that the same target retrieved multiple times maintains equality
        let firstRetrieval = try await MediaCapture.availableCaptureTargets(ofType: .screen)
        let secondRetrieval = try await MediaCapture.availableCaptureTargets(ofType: .screen)
        
        guard let firstScreen = firstRetrieval.first, let secondScreen = secondRetrieval.first else {
            XCTFail("Could not retrieve screen targets")
            return
        }
        
        // Screens with the same displayID should be considered equal
        XCTAssertEqual(firstScreen.displayID, secondScreen.displayID, "Same screen should have same displayID")
        XCTAssertEqual(firstScreen.frame, secondScreen.frame, "Same screen should have same frame")
        
        // Test capturing with both targets
        let expectation1 = expectation(description: "Capture with first target")
        var receivedData1 = false
        
        _ = try await mediaCapture.startCapture(
            target: firstScreen,
            mediaHandler: { _ in
                if !receivedData1 {
                    receivedData1 = true
                    expectation1.fulfill()
                }
            }
        )
        
        await fulfillment(of: [expectation1], timeout: 5.0)
        await mediaCapture.stopCapture()
        
        try await Task.sleep(for: .milliseconds(500))
        
        // Verify that capturing works with the second instance of the same screen
        let expectation2 = expectation(description: "Capture with second target")
        var receivedData2 = false
        
        _ = try await mediaCapture.startCapture(
            target: secondScreen,
            mediaHandler: { _ in
                if !receivedData2 {
                    receivedData2 = true
                    expectation2.fulfill()
                }
            }
        )
        
        await fulfillment(of: [expectation2], timeout: 5.0)
        await mediaCapture.stopCapture()
        
        XCTAssertTrue(receivedData1, "Should receive data with first target")
        XCTAssertTrue(receivedData2, "Should receive data with second target")
    }

    func testTargetFiltering() async throws {
        // Test the internal filtering of the target retrieval method
        let allTargets = try await MediaCapture.availableCaptureTargets(ofType: .all)
        let screenTargets = try await MediaCapture.availableCaptureTargets(ofType: .screen)
        let windowTargets = try await MediaCapture.availableCaptureTargets(ofType: .window)
        
        // Verify that targets are correctly separated by type
        XCTAssertTrue(screenTargets.allSatisfy { $0.isDisplay }, "Screen targets should all be displays")
        XCTAssertTrue(windowTargets.allSatisfy { $0.isWindow }, "Window targets should all be windows")
        
        // Verify that all targets are correctly classified
        let allDisplays = allTargets.filter { $0.isDisplay }
        let allWindows = allTargets.filter { $0.isWindow }
        
        XCTAssertEqual(screenTargets.count, allDisplays.count, "Screen target count should match displays in all targets")
        XCTAssertEqual(windowTargets.count, allWindows.count, "Window target count should match windows in all targets")
        
        // Verify properties specific to each target type
        for target in screenTargets {
            XCTAssertGreaterThan(target.displayID, 0, "Display ID should be positive")
            XCTAssertEqual(target.windowID, 0, "Window ID should be 0 for displays")
        }
        
        for target in windowTargets {
            XCTAssertGreaterThan(target.windowID, 0, "Window ID should be positive")
            XCTAssertEqual(target.displayID, 0, "Display ID should be 0 for windows")
        }
    }

    // Test retrieving window-only targets
    func testWindowTargetsRetrieval() async throws {
        // Test retrieving window-only targets
        let windowTargets = try await MediaCapture.availableCaptureTargets(ofType: .window)
        
        // Some test environments might not have windows available
        if !windowTargets.isEmpty {
            // Verify that all elements are windows
            for target in windowTargets {
                XCTAssertTrue(target.isWindow, "Target should be a window")
                XCTAssertFalse(target.isDisplay, "Target should not be a display")
                XCTAssertGreaterThan(target.windowID, 0, "Window ID should be valid")
            }
        } else {
            print("No windows available for testing window target retrieval")
        }
    }
    
    // Test capturing from window targets
    func testWindowCapture() async throws {
        // Get window targets
        let windowTargets = try await MediaCapture.availableCaptureTargets(ofType: .window)
        
        // Skip test if no windows available
        guard !windowTargets.isEmpty, let windowTarget = windowTargets.first else {
            print("No windows available for testing window capture")
            return
        }
        
        // Set up expectations
        let expectation = expectation(description: "Capture from window")
        var receivedData = false
        
        do {
            // Start capturing from the window
            _ = try await mediaCapture.startCapture(
                target: windowTarget,
                mediaHandler: { media in
                    if !receivedData {
                        receivedData = true
                        expectation.fulfill()
                    }
                }
            )
            
            // Wait for media data
            await fulfillment(of: [expectation], timeout: 5.0)
            XCTAssertTrue(receivedData, "Should have received media data from window")
            
            // Stop the capture
            await mediaCapture.stopCapture()
        } catch {
            // Window capture might fail (e.g., hidden windows)
            print("Window capture test skipped: \(error.localizedDescription)")
        }
    }
}
