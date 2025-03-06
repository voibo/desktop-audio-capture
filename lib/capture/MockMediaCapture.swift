import Foundation
import OSLog
import CoreGraphics
import AVFoundation

/// A class for mock capture implementation.
public class MockMediaCapture: MediaCapture, @unchecked Sendable {
    private let logger = Logger(subsystem: "org.voibo.desktop-audio-capture", category: "MockMediaCapture")
    private var mockTimer: Timer?
    private var audioTimer: Timer?
    private var running: Bool = false
    private var mediaHandler: ((StreamableMediaData) -> Void)?
    private var errorHandler: ((String) -> Void)?
    
    // Holds mock settings
    private var currentImageFormat: ImageFormat = .jpeg
    private var currentImageQuality: ImageQuality = .standard
    private var currentFrameRate: Double = 15.0
    
    /// Sets the ID range to treat as invalid targets
    private let invalidWindowIDThreshold: CGWindowID = 10000
    private let invalidDisplayIDThreshold: CGDirectDisplayID = 10000
    
    public override init() {
        super.init()
        logger.debug("MockMediaCapture initialized")
    }
    
    // MARK: - Override Methods
    
    /// Mock version of startCapture - same signature as MediaCapture
    public override func startCapture(
        target: MediaCaptureTarget,
        mediaHandler: @escaping (StreamableMediaData) -> Void,
        errorHandler: ((String) -> Void)? = nil,
        framesPerSecond: Double = 30.0,
        quality: CaptureQuality = .high,
        imageFormat: ImageFormat = .jpeg,
        imageQuality: ImageQuality = .standard,
        audioSampleRate: Int = 48000,
        audioChannelCount: Int = 2
    ) async throws -> Bool {
        if running {
            return false
        }
        
        self.mediaHandler = mediaHandler
        self.errorHandler = errorHandler
        self.currentImageFormat = imageFormat
        self.currentImageQuality = imageQuality
        self.currentFrameRate = framesPerSecond
        
        // Simulate invalid target
        if target.windowID > invalidWindowIDThreshold || target.displayID > invalidDisplayIDThreshold {
            let errorMsg = "Mock error: Invalid target ID - windowID: \(target.windowID), displayID: \(target.displayID)"
            logger.debug("Throwing error for invalid mock target: \(errorMsg)")
            
            // Call errorHandler if it exists
            errorHandler?(errorMsg)
            
            // Throw exception
            throw NSError(
                domain: "MockMediaCapture", 
                code: 100, 
                userInfo: [NSLocalizedDescriptionKey: errorMsg]
            )
        }
        
        // Start mock capture
        startMockCapture(
            framesPerSecond: framesPerSecond,
            imageFormat: imageFormat,
            imageQuality: imageQuality
        )
        
        running = true
        return true
    }
    
    /// Mock version of stopCapture
    public override func stopCapture() async {
        if running {
            stopMockTimers()
            running = false
            mediaHandler = nil
        }
    }
    
    /// Mock version of synchronous stop
    public override func stopCaptureSync() {
        if running {
            stopMockTimers()
            running = false
            mediaHandler = nil
            errorHandler = nil
        }
    }
    
    /// Check capture status
    public override func isCapturing() -> Bool {
        return running
    }
    
    /// Static method for getting mock targets
    public override class func availableCaptureTargets(ofType type: CaptureTargetType = .all) async throws -> [MediaCaptureTarget] {
        return mockCaptureTargets(type)
    }

    public override class func checkScreenCapturePermission() async -> Bool {
        return true
    }
    
    // MARK: - Mock-Specific Methods
    
    /// Stop timers
    private func stopMockTimers() {
        if let timer = mockTimer {
            timer.invalidate()
            mockTimer = nil
        }
        
        if let timer = audioTimer {
            timer.invalidate()
            audioTimer = nil
        }
    }
    
    /// Start mock capture
    private func startMockCapture(
        framesPerSecond: Double,
        imageFormat: ImageFormat,
        imageQuality: ImageQuality
    ) {
        logger.debug("Starting mock capture with format: \(imageFormat.rawValue)")
        
        // Clear existing timers
        stopMockTimers()
        
        // Adjust frame rate
        let includeVideo = framesPerSecond > 0
        let interval = includeVideo ? max(0.1, 1.0 / framesPerSecond) : 0
        
        // Set up timer for audio delivery
        audioTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.generateMockMedia(
                timestamp: Date().timeIntervalSince1970,
                includeVideo: false
            )
        }
        scheduleTimer(audioTimer)
        
        // Set up timer for video delivery
        if includeVideo {
            // Send the first frame immediately
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.generateMockMedia(
                    timestamp: Date().timeIntervalSince1970,
                    includeVideo: true
                )
            }
            
            // Set up regular video frame delivery
            mockTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.generateMockMedia(
                    timestamp: Date().timeIntervalSince1970,
                    includeVideo: true
                )
            }
            scheduleTimer(mockTimer)
        }
    }
    
    /// Generate mock media data
    private func generateMockMedia(timestamp: Double, includeVideo: Bool) {
        // Video buffer
        var videoBuffer: Data? = nil
        var videoInfo: StreamableMediaData.Metadata.VideoInfo? = nil
        
        if includeVideo {
            // Simple video data
            let width = 640
            let height = 480
            let bytesPerRow = width * 4
            
            videoBuffer = Data(repeating: 0xAA, count: width * height * 4)
            videoInfo = StreamableMediaData.Metadata.VideoInfo(
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                pixelFormat: UInt32(kCVPixelFormatType_32BGRA),
                format: currentImageFormat.rawValue,
                quality: currentImageQuality.value
            )
        }
        
        // Simple audio data
        let sampleRate: Double = 44100
        let channelCount: UInt32 = 2
        let seconds: Double = 0.1
        let pcmDataSize = Int(sampleRate * Double(channelCount) * seconds) * MemoryLayout<Float>.size
        
        let audioBuffer = Data(repeating: 0x55, count: pcmDataSize)
        let audioInfo = StreamableMediaData.Metadata.AudioInfo(
            sampleRate: sampleRate,
            channelCount: Int(channelCount),
            bytesPerFrame: UInt32(MemoryLayout<Float>.size * Int(channelCount)),
            frameCount: UInt32(pcmDataSize / (MemoryLayout<Float>.size * Int(channelCount)))
        )
        
        // Build media data
        let metadata = StreamableMediaData.Metadata(
            timestamp: timestamp,
            hasVideo: videoBuffer != nil,
            hasAudio: true,
            videoInfo: videoInfo,
            audioInfo: audioInfo
        )
        
        let mediaData = StreamableMediaData(
            metadata: metadata,
            videoBuffer: videoBuffer,
            audioBuffer: audioBuffer,
            audioOriginal: nil 
        )
        
        // Callback on the main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let handler = self.mediaHandler else { return }
            handler(mediaData)
        }
    }
    
    /// Helper for setting up timers
    private func scheduleTimer(_ timer: Timer?) {
        guard let timer = timer else { return }
        RunLoop.main.add(timer, forMode: .common)
    }
    
    /// Mock target generation
    public static func mockCaptureTargets(_ type: CaptureTargetType) -> [MediaCaptureTarget] {
        var targets = [MediaCaptureTarget]()
        
        // Mock main display
        let mockDisplay = MediaCaptureTarget(
            displayID: 1,
            title: "Mock Display 1",
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        
        // Mock window
        let mockWindow1 = MediaCaptureTarget(
            windowID: 1,
            title: "Mock Window 1",
            applicationName: "Mock App 1",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        
        // Multiple mock windows
        let mockWindow2 = MediaCaptureTarget(
            windowID: 2,
            title: "Mock Window 2",
            applicationName: "Mock App 2",
            frame: CGRect(x: 0, y: 0, width: 1024, height: 768)
        )
        
        // Filter based on specified type
        switch type {
        case .all:
            targets.append(mockWindow1)
            targets.append(mockWindow2)
            targets.append(mockDisplay)
        case .screen:
            targets.append(mockDisplay)
        case .window:
            targets.append(mockWindow1)
            targets.append(mockWindow2)
        }
        
        return targets
    }
}
