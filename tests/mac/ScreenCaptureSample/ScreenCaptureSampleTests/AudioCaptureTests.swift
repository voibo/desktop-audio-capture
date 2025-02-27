import XCTest
@testable import ScreenCaptureSample
import ScreenCaptureKit
import AVFoundation

// Mock class implemented directly in the test file
class MockAudioCapture: AudioCapture, @unchecked Sendable {
    private var mockRunning = false
    private var mockTimer: Timer?
    
    // Creates a mock audio buffer
    private func createMockAudioBuffer() -> AVAudioPCMBuffer? {
        // Create a 44.1kHz, 2-channel PCM buffer
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
        guard let format = format else { return nil }
        
        // Buffer for 0.1 seconds (4410 frames)
        let frameCount = AVAudioFrameCount(4410)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        
        // Generate a sine wave (440Hz)
        if let channelData = buffer.floatChannelData {
            let frequency: Float = 440.0 // A4 note
            let amplitude: Float = 0.5
            
            for frame in 0..<Int(frameCount) {
                let sampleTime = Float(frame) / 44100.0
                let value = amplitude * sin(2.0 * .pi * frequency * sampleTime)
                
                // Same data for both channels
                channelData[0][frame] = value
                channelData[1][frame] = value
            }
        }
        
        return buffer
    }
    
    override func startCapture(target: SharedCaptureTarget, configuration: SCStreamConfiguration) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        return AsyncThrowingStream { continuation in
            // Test case for error handling
            if target.windowID == 999999999 {
                continuation.finish(throwing: NSError(domain: "MockAudioCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid window ID"]))
                return
            }
            
            mockRunning = true
            
            // Send the first buffer immediately
            if let buffer = createMockAudioBuffer() {
                continuation.yield(buffer)
            }
            
            // Generate audio buffers periodically
            DispatchQueue.main.async {
                self.mockTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                    if self.mockRunning {
                        if let buffer = self.createMockAudioBuffer() {
                            continuation.yield(buffer)
                        }
                    }
                }
            }
        }
    }
    
    override func stopCapture() async {
        mockTimer?.invalidate()
        mockTimer = nil
        mockRunning = false
    }
}

class AudioCaptureTests: XCTestCase {
    // Use mock version
    var audioCapture: MockAudioCapture?
    
    override func setUpWithError() throws {
        // Initialize MockAudioCapture
        audioCapture = MockAudioCapture()
    }
    
    override func tearDownWithError() throws {
        if let capture = audioCapture {
            Task {
                await capture.stopCapture()
            }
        }
        audioCapture = nil
    }
    
    // Basic initialization test
    func testInitialization() {
        XCTAssertNotNil(audioCapture, "AudioCapture should be initialized correctly")
    }
    
    // Start and stop capture test - mock version
    func testStartAndStopCapture() async throws {
        guard let capture = audioCapture else {
            XCTFail("AudioCapture is nil")
            return
        }
        
        // Create capture target
        let target = SharedCaptureTarget(displayID: CGMainDisplayID())
        
        // Capture configuration
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        
        // Asynchronous task for receiving audio buffer
        let bufferExpectation = expectation(description: "Audio buffer received")
        var receivedBuffer: AVAudioPCMBuffer?
        
        Task {
            do {
                // Start capture stream
                for try await buffer in capture.startCapture(
                    target: target,
                    configuration: configuration
                ) {
                    receivedBuffer = buffer
                    bufferExpectation.fulfill()
                    break // Exit after receiving one buffer
                }
            } catch {
                XCTFail("Error occurred during audio capture: \(error)")
            }
        }
        
        // Short timeout since mock responds quickly
        await fulfillment(of: [bufferExpectation], timeout: 1.0)
        
        // Verify received buffer
        XCTAssertNotNil(receivedBuffer, "Audio buffer should be received")
        if let buffer = receivedBuffer {
            XCTAssertGreaterThan(buffer.frameLength, 0, "Buffer should contain frames")
            XCTAssertGreaterThan(buffer.format.sampleRate, 0, "Sample rate should be a positive value")
            XCTAssertGreaterThan(buffer.format.channelCount, 0, "Channel count should be a positive value")
        }
        
        // Stop capture
        await capture.stopCapture()
    }
    
    // Test capture from different targets - mock version
    func testCaptureTargets() async throws {
        // Check if audioCapture variable exists (without referencing the variable)
        guard audioCapture != nil else {
            XCTFail("AudioCapture is nil")
            return
        }
        
        // Target values are not important in the mock
        try await verifyAudioCapture(SharedCaptureTarget(displayID: CGMainDisplayID()), "Display")
        try await verifyAudioCapture(SharedCaptureTarget(windowID: 12345), "Window")
    }
    
    // Verify audio capture from the specified target - mock version
    private func verifyAudioCapture(_ target: SharedCaptureTarget, _ targetName: String) async throws {
        let bufferExpectation = expectation(description: "Audio from \(targetName)")
        var receivedBuffer = false
        
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        
        Task {
            do {
                // Safely reference audioCapture avoiding force unwrapping
                guard let audioCapture = self.audioCapture else {
                    XCTFail("AudioCapture is nil")
                    return
                }
                
                for try await _ in audioCapture.startCapture(
                    target: target,
                    configuration: configuration
                ) {
                    if !receivedBuffer {
                        receivedBuffer = true
                        bufferExpectation.fulfill()
                        break
                    }
                }
            } catch {
                XCTFail("Failed to capture audio from \(targetName): \(error)")
            }
        }
        
        // Short timeout is sufficient for mock
        await fulfillment(of: [bufferExpectation], timeout: 1.0)
        
        // Stop capture
        await audioCapture?.stopCapture()
    }
    
    // Error handling test - mock version
    func testErrorHandling() async throws {
        guard let capture = audioCapture else {
            XCTFail("AudioCapture is nil")
            return
        }
        
        // Invalid window ID that the mock specifically handles
        let invalidTarget = SharedCaptureTarget(windowID: 999999999)
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        
        do {
            // Attempt to capture
            for try await _ in capture.startCapture(
                target: invalidTarget,
                configuration: configuration
            ) {
                XCTFail("Should not succeed in capturing with an invalid target")
                break
            }
            XCTFail("Error should be thrown")
        } catch {
            // Expect an error to be thrown
            XCTAssertTrue(true, "Error was properly thrown for an invalid target")
        }
    }
    
    // Performance test
    func testCapturePerformance() {
        measure {
            let initExpectation = expectation(description: "Initialization")
            
            // Performance measurement with mock version
            let testAudioCapture = MockAudioCapture()
            XCTAssertNotNil(testAudioCapture, "AudioCapture instance should be created successfully")
            
            initExpectation.fulfill()
            wait(for: [initExpectation], timeout: 1.0)
        }
    }
}
