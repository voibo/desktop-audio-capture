import Foundation
import AVFoundation
import CoreGraphics
import ScreenCaptureKit
@testable import MediaCaptureTest

/// Mock class for MediaCapture - for testing purposes
class MockMediaCapture: MediaCapture, @unchecked Sendable {
    // State management for mock implementation
    private var mockRunning = false
    private var mockTimer: Timer?
    private var mediaHandler: ((StreamableMediaData) -> Void)?
    private var errorHandler: ((String) -> Void)?
    
    // Check capture state (override)
    public override func isCapturing() -> Bool {
        return mockRunning
    }
    
    // Start capture (override)
    public override func startCapture(
        target: MediaCaptureTarget,
        mediaHandler: @escaping (StreamableMediaData) -> Void,
        errorHandler: ((String) -> Void)? = nil,
        framesPerSecond: Double = 30.0,
        quality: CaptureQuality = .high
    ) async throws -> Bool {
        // Test error conditions
        if target.windowID == 99999 {
            if let errorHandler = errorHandler {
                errorHandler("Mock error: Invalid window ID")
            }
            throw NSError(domain: "MockCapture", code: 100, userInfo: [NSLocalizedDescriptionKey: "Invalid window ID"])
        }
        
        if mockRunning {
            return false
        }
        
        // Save handlers
        self.mediaHandler = mediaHandler
        self.errorHandler = errorHandler
        mockRunning = true
        
        // Start mock media generation
        startMockMediaGeneration(fps: framesPerSecond)
        
        return true
    }
    
    // Stop capture (override)
    public override func stopCapture() async {
        mockTimer?.invalidate()
        mockTimer = nil
        mockRunning = false
        mediaHandler = nil
        errorHandler = nil
    }
    
    // Stop capture synchronously (override)
    public override func stopCaptureSync() {
        mockTimer?.invalidate()
        mockTimer = nil
        mockRunning = false
        mediaHandler = nil
        errorHandler = nil
    }
    
    // Generate mock media data
    private func createMockMediaData() -> StreamableMediaData {
        // Create mock video buffer
        let width = 640
        let height = 480
        let bytesPerRow = width * 4
        let data = Data(count: bytesPerRow * height)
        
        // Create mock audio buffer
        let audioData = Data(count: 4096)
        
        // Create metadata
        let metadata = StreamableMediaData.Metadata(
            timestamp: Date().timeIntervalSince1970,
            hasVideo: true,
            hasAudio: true,
            videoInfo: StreamableMediaData.Metadata.VideoInfo(
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                pixelFormat: 32
            ),
            audioInfo: StreamableMediaData.Metadata.AudioInfo(
                sampleRate: 44100,
                channelCount: 2,
                bytesPerFrame: 4,
                frameCount: 1024
            )
        )
        
        return StreamableMediaData(
            metadata: metadata,
            videoBuffer: data,
            audioBuffer: audioData
        )
    }
    
    // Generate mock media at specified frame rate
    private func startMockMediaGeneration(fps: Double) {
        // Create a background task to generate mock media data
        Task.detached { [weak self] in
            guard let self = self else { return }
            
            // Calculate delay between frames based on fps
            let delayInSeconds = fps > 0 ? 1.0 / fps : 0.1
            
            while self.mockRunning {
                // Generate mock media data
                let mediaData = self.createMockMediaData()
                
                // Send to handler on main thread
                Task { @MainActor in
                    self.mediaHandler?(mediaData)
                }
                
                // Delay based on frame rate
                try? await Task.sleep(for: .seconds(delayInSeconds))
            }
        }
    }

    // Provide mock window and display data
    override class func availableCaptureTargets(ofType type: CaptureTargetType = .all) async throws -> [MediaCaptureTarget] {
        let mockTargets: [MediaCaptureTarget]
        
        switch type {
        case .screen:
            mockTargets = [
                MediaCaptureTarget(
                    displayID: 1,
                    title: "Mock Display 1",
                    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
                )
            ]
        case .window:
            mockTargets = [
                MediaCaptureTarget(
                    windowID: 1,
                    title: "Mock Window 1",
                    bundleID: "com.example.app1",
                    applicationName: "Mock App 1",
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600)
                ),
                MediaCaptureTarget(
                    windowID: 2,
                    title: "Mock Window 2",
                    bundleID: "com.example.app2",
                    applicationName: "Mock App 2", 
                    frame: CGRect(x: 100, y: 100, width: 800, height: 600)
                )
            ]
        case .all:
            mockTargets = [
                MediaCaptureTarget(
                    displayID: 1,
                    title: "Mock Display 1",
                    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
                ),
                MediaCaptureTarget(
                    windowID: 1,
                    title: "Mock Window 1",
                    bundleID: "com.example.app1",
                    applicationName: "Mock App 1",
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600)
                ),
                MediaCaptureTarget(
                    windowID: 2,
                    title: "Mock Window 2",
                    bundleID: "com.example.app2",
                    applicationName: "Mock App 2",
                    frame: CGRect(x: 100, y: 100, width: 800, height: 600)
                )
            ]
        }
        
        return mockTargets
    }
}
