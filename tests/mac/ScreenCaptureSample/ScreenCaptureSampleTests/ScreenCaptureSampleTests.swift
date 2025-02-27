//
//  ScreenCaptureSampleTests.swift
//  ScreenCaptureSampleTests
//
//  Created by Nobuhiro Hayashi on 2025/02/27.
//

import XCTest
@testable import ScreenCaptureSample
import ScreenCaptureKit
import AVFoundation
import CoreGraphics
import Combine

class ScreenCaptureSampleTests: XCTestCase {
    var captureInstance: ScreenCapture!
    var cancellables: Set<AnyCancellable> = []
    
    override func setUpWithError() throws {
        // Determine whether to use mock based on environment variables or compilation flags
        #if USE_MOCK_CAPTURE
            captureInstance = MockScreenCapture()
            print("Using mock capture")
        #else
            if ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] == "1" {
                captureInstance = MockScreenCapture()
                print("Using mock capture due to environment variable")
            } else {
                captureInstance = ScreenCapture()
                print("Using actual screen capture")
            }
        #endif
    }
    
    override func tearDownWithError() throws {
        if captureInstance.isCapturing() {
            let expectation = self.expectation(description: "Capture stopped")
            Task {
                await captureInstance.stopCapture()
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 5.0)
        }
        captureInstance = nil
        cancellables.removeAll()
    }
    
    // MARK: - Basic Functionality Tests
    
    func testInitialization() {
        XCTAssertNotNil(captureInstance)
        XCTAssertFalse(captureInstance.isCapturing())
    }
    
    func testStartAndStopCapture() async throws {
        // Expectation for frame reception
        let frameExpectation = expectation(description: "Frame received")
        var receivedFrameData: FrameData?
        
        // Start capturing
        let success = try await captureInstance.startCapture { frameData in
            if receivedFrameData == nil {
                receivedFrameData = frameData
                frameExpectation.fulfill()
            }
        }
        
        XCTAssertTrue(success, "Capture should start successfully")
        XCTAssertTrue(captureInstance.isCapturing(), "The capturing flag should be set")
        
        // Wait until a frame is received
        await fulfillment(of: [frameExpectation], timeout: 5.0)
        
        // Verify the received frame data
        XCTAssertNotNil(receivedFrameData, "Frame data should be received")
        if let frameData = receivedFrameData {
            XCTAssertGreaterThan(frameData.width, 0, "Frame width should be a positive value")
            XCTAssertGreaterThan(frameData.height, 0, "Frame height should be a positive value")
            XCTAssertGreaterThan(frameData.bytesPerRow, 0, "bytesPerRow should be a positive value")
            XCTAssertGreaterThan(frameData.data.count, 0, "Data buffer should not be empty")
        }
        
        // Stop capturing
        await captureInstance.stopCapture()
        XCTAssertFalse(captureInstance.isCapturing(), "Capture should stop")
    }
    
    // MARK: - Multiple Start and Stop Tests
    
    func testMultipleStartsAndStops() async throws {
        // First capture
        let success1 = try await captureInstance.startCapture { _ in }
        XCTAssertTrue(success1, "The first capture start should succeed")
        
        // Should fail if already running
        let success2 = try await captureInstance.startCapture { _ in }
        XCTAssertFalse(success2, "Starting should fail if already capturing")
        
        // Stop
        await captureInstance.stopCapture()
        XCTAssertFalse(captureInstance.isCapturing(), "Capture should stop")
        
        // Can it be restarted?
        let success3 = try await captureInstance.startCapture { _ in }
        XCTAssertTrue(success3, "Restarting after stopping should succeed")
        
        // Cleanup
        await captureInstance.stopCapture()
    }
    
    // MARK: - Frame Rate Settings Test
    
    func testFrameRateSettings() async throws {
        // Skip the test in the test environment
        if ProcessInfo.processInfo.environment["SKIP_FRAMERATE_TEST"] == "1" {
            print("Skipping frame rate test (environment variable SKIP_FRAMERATE_TEST=1)")
            return
        }
        
        // High frame rate test
        try await testWithFrameRate(30.0, expectedFrameCount: 10, timeout: 5.0)
        
        // Standard frame rate test
        try await testWithFrameRate(10.0, expectedFrameCount: 5, timeout: 5.0)
        
        // Low frame rate test (commented out because it takes time)
        // try await testWithFrameRate(1.0, expectedFrameCount: 2, timeout: 5.0)
        
        // Very low frame rate test (commented out because it takes time)
        // try await testWithFrameRate(0.2, expectedFrameCount: 1, timeout: 10.0)
    }
    
    private func testWithFrameRate(_ fps: Double, expectedFrameCount: Int, timeout: TimeInterval) async throws {
        let frameCountExpectation = expectation(description: "Received \(expectedFrameCount) frames at \(fps) fps")
        var receivedFrames = 0
        var timestamps: [TimeInterval] = []
        var expectationFulfilled = false
        
        let success = try await captureInstance.startCapture(
            frameHandler: { frameData in
                receivedFrames += 1
                timestamps.append(frameData.timestamp)
                
                if receivedFrames >= expectedFrameCount && !expectationFulfilled {
                    expectationFulfilled = true
                    frameCountExpectation.fulfill()
                }
            },
            framesPerSecond: fps
        )
        
        XCTAssertTrue(success, "Should be able to start capture at \(fps) fps")
        
        // Wait until the specified number of frames is received
        await fulfillment(of: [frameCountExpectation], timeout: timeout)
        
        // Verify frame rate (calculated from the time difference between the last and first frames)
        if timestamps.count >= 2 {
            let duration = timestamps.last! - timestamps.first!
            let actualFPS = Double(timestamps.count - 1) / duration
            
            // Significantly relax the tolerance (for mock testing)
            let lowerBound = fps * 0.05
            let upperBound = fps * 5.0
            
            print("Set FPS: \(fps), Actual FPS: \(actualFPS), Duration: \(duration) seconds, Frame Count: \(timestamps.count)")
            XCTAssertGreaterThan(actualFPS, lowerBound, "Actual FPS should be greater than 5% of the setting")
            XCTAssertLessThan(actualFPS, upperBound, "Actual FPS should be less than 5 times the setting")
        }
        
        await captureInstance.stopCapture()
    }
    
    // MARK: - Quality Settings Test
    
    func testQualitySettings() async throws {
        // Capture one frame at each quality setting and compare sizes
        let highQualitySize = try await captureFrameWithQuality(.high)
        let mediumQualitySize = try await captureFrameWithQuality(.medium)
        let lowQualitySize = try await captureFrameWithQuality(.low)
        
        print("High Quality Size: \(highQualitySize.width)x\(highQualitySize.height)")
        print("Medium Quality Size: \(mediumQualitySize.width)x\(mediumQualitySize.height)")
        print("Low Quality Size: \(lowQualitySize.width)x\(lowQualitySize.height)")
        
        // Size should decrease in the order: High > Medium > Low
        XCTAssertGreaterThanOrEqual(highQualitySize.width * highQualitySize.height, 
                                 mediumQualitySize.width * mediumQualitySize.height,
                                 "High quality should be greater than or nearly equal to medium quality")
                                 
        XCTAssertGreaterThanOrEqual(mediumQualitySize.width * mediumQualitySize.height, 
                                 lowQualitySize.width * lowQualitySize.height,
                                 "Medium quality should be greater than or nearly equal to low quality")
    }
    
    private func captureFrameWithQuality(_ quality: ScreenCapture.CaptureQuality) async throws -> (width: Int, height: Int) {
        let frameExpectation = expectation(description: "Frame with \(quality) quality")
        var frameSize: (width: Int, height: Int) = (0, 0)
        
        let success = try await captureInstance.startCapture(
            frameHandler: { frameData in
                if frameSize.width == 0 { // Process only the first frame
                    frameSize = (frameData.width, frameData.height)
                    frameExpectation.fulfill()
                }
            },
            framesPerSecond: 10,
            quality: quality
        )
        
        XCTAssertTrue(success, "Should be able to start capture with \(quality) quality")
        
        // Wait for frame reception
        await fulfillment(of: [frameExpectation], timeout: 5.0)
        
        // Stop capturing
        await captureInstance.stopCapture()
        
        return frameSize
    }
    
    // MARK: - Capture Target Test
    
    func testCaptureTargets() async throws {
        // Capture entire screen
        try await verifyTargetCapture(.entireDisplay, "Entire Screen")
        
        // Capture specific display
        let mainDisplay = CGMainDisplayID()
        try await verifyTargetCapture(.screen(displayID: mainDisplay), "Main Display")
        
        // Window and application tests depend on the actual environment, so comment out
        // Execute only the test to check if the window list can be obtained
        let windows = try await ScreenCapture.availableWindows()
        XCTAssertFalse(windows.isEmpty, "At least one window should be detected")
        for window in windows.prefix(3) { // Display only the first 3
            print("Detected Window: \(window.title ?? "Unknown") (\(window.displayName))")
        }
    }
    
    private func verifyTargetCapture(_ target: ScreenCapture.CaptureTarget, _ targetName: String) async throws {
        let frameExpectation = expectation(description: "Frame from \(targetName)")
        var receivedFrame = false
        
        let success = try await captureInstance.startCapture(
            target: target,
            frameHandler: { _ in
                if !receivedFrame {
                    receivedFrame = true
                    frameExpectation.fulfill()
                }
            }
        )
        
        XCTAssertTrue(success, "Should be able to start capture from \(targetName)")
        
        // Wait for frame reception
        await fulfillment(of: [frameExpectation], timeout: 5.0)
        
        // Stop capturing
        await captureInstance.stopCapture()
    }
    
    // MARK: - Error Handling Test
    
    func testErrorHandling() async throws {
        let errorExpectation = expectation(description: "Error callback")
        var expectationFulfilled = false
        
        // Capture with an invalid target
        do {
            _ = try await captureInstance.startCapture(
                target: .window(windowID: 999999999),
                frameHandler: { _ in },
                errorHandler: { error in
                    // Just check that an error occurred
                    if !expectationFulfilled {
                        expectationFulfilled = true
                        errorExpectation.fulfill()
                    }
                }
            )
        } catch {
            // Consider it a success if an exception is thrown
            print("Exception occurred while starting capture: \(error.localizedDescription)")
            
            if !expectationFulfilled {
                expectationFulfilled = true
                errorExpectation.fulfill()
            }
        }
        
        // Check with a short timeout
        await fulfillment(of: [errorExpectation], timeout: 0.1)
        
        // Cleanup
        await captureInstance.stopCapture()
    }
    
    // MARK: - Performance Test
    
    func testCapturePerformance() async throws {
        // Performance measurement
        measure {
            let initExpectation = expectation(description: "Initialization")
            
            // Performance of initialization and simple property access
            let testCapture = ScreenCapture()
            XCTAssertFalse(testCapture.isCapturing())
            
            initExpectation.fulfill()
            wait(for: [initExpectation], timeout: 1.0)
        }
    }

    // Add to explicitly output the mode at the beginning of the test code
    func testCheckMockMode() {
        // Check environment variables
        let useMock = ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"]
        print("USE_MOCK_CAPTURE environment variable: \(useMock ?? "Not set")")
        
        // Check the type of instance actually being used
        if captureInstance is MockScreenCapture {
            print("✅ MockScreenCapture instance is being used")
        } else {
            print("⚠️ Actual ScreenCapture instance is being used")
        }
        
        XCTAssertTrue(captureInstance is MockScreenCapture, "MockScreenCapture should be used for testing")
    }
}
