import AppKit
import Foundation
import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import OSLog

/// Represents a capture target (window or display).
public struct MediaCaptureTarget: Identifiable, Equatable, Hashable {

    /// Unique identifier for Identifiable protocol
    public var id: String {
        // Generates a unique ID using a combination of windowID and displayID
        if isWindow {
            return "window-\(windowID)"
        } else {
            return "display-\(displayID)"
        }
    }
    
    /// Window ID.
    public let windowID: CGWindowID
    
    /// Display ID.
    public let displayID: CGDirectDisplayID
    
    /// Title.
    public let title: String?
    
    /// Bundle ID.
    public let bundleID: String?
    
    /// Frame.
    public let frame: CGRect
    
    /// Application name.
    public let applicationName: String?
    
    /// Indicates whether it is a window.
    public var isWindow: Bool { windowID > 0 }
    
    /// Indicates whether it is a display.
    public var isDisplay: Bool { displayID > 0 }
    
    /// Initializes a new capture target.
    public init(
        windowID: CGWindowID = 0, 
        displayID: CGDirectDisplayID = 0, 
        title: String? = nil, 
        bundleID: String? = nil, 
        applicationName: String? = nil,
        frame: CGRect = .zero
    ) {
        self.windowID = windowID
        self.displayID = displayID
        self.title = title
        self.bundleID = bundleID
        self.applicationName = applicationName
        self.frame = frame
    }
    
    /// Creates a `MediaCaptureTarget` from an `SCWindow`.
    public static func from(window: SCWindow) -> MediaCaptureTarget {
        return MediaCaptureTarget(
            windowID: window.windowID,
            title: window.title,
            bundleID: window.owningApplication?.bundleIdentifier,
            applicationName: window.owningApplication?.applicationName,
            frame: window.frame
        )
    }
    
    /// Creates a `MediaCaptureTarget` from an `SCDisplay`.
    public static func from(display: SCDisplay) -> MediaCaptureTarget {
        return MediaCaptureTarget(
            displayID: display.displayID,
            title: "Display \(display.displayID)",
            frame: CGRect(x: 0, y: 0, width: display.width, height: display.height)
        )
    }
    
    // Hashable implementation
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(windowID)
        hasher.combine(displayID)
    }
}

/// Frame data structure.
public struct FrameData {
    private var _dataStorage: Data
    
    public var data: Data { return _dataStorage }
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let timestamp: Double
    public let pixelFormat: UInt32
    
    public init(data: Data, width: Int, height: Int, bytesPerRow: Int, timestamp: Double, pixelFormat: UInt32) {
        self._dataStorage = data
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.timestamp = timestamp
        self.pixelFormat = pixelFormat
        assert(data.count >= bytesPerRow * height, "Data size is insufficient for specified dimensions")
    }
}

/// Structure to hold synchronized media data.
public struct SynchronizedMedia {
    public let frame: FrameData?
    public let audio: AVAudioPCMBuffer?
    public let timestamp: Double
    
    public var hasFrame: Bool { return frame != nil }
    public var hasAudio: Bool { return audio != nil }
    public var isComplete: Bool { return hasFrame && hasAudio }
}

/// Simple data structure for Node.js integration.
public struct StreamableMediaData {
    /// Metadata (JSON serializable).
    public struct Metadata: Codable {
        public let timestamp: Double
        public let hasVideo: Bool
        public let hasAudio: Bool
        
        /// Video metadata.
        public struct VideoInfo: Codable {
            public let width: Int
            public let height: Int
            public let bytesPerRow: Int
            public let pixelFormat: UInt32
            public let format: String  // "raw" or "jpeg"
            public let quality: Float? // JPEG quality setting value (0.0-1.0)
        }
        
        /// Audio metadata.
        public struct AudioInfo: Codable {
            public let sampleRate: Double
            public let channelCount: Int
            public let bytesPerFrame: UInt32
            public let frameCount: UInt32
        }
        
        public let videoInfo: VideoInfo?
        public let audioInfo: AudioInfo?
    }
    
    /// Metadata (can be processed as JSON).
    public let metadata: Metadata
    
    /// Video data (transferred as Raw Buffer).
    public let videoBuffer: Data?
    
    /// Audio data (transferred as Raw Buffer).
    public let audioBuffer: Data?
    
    /// Original audio buffer (e.g., AVAudioPCMBuffer).
    public let audioOriginal: Any?
}

// Codable conformance extension
extension StreamableMediaData: Codable {
    enum CodingKeys: String, CodingKey {
        case metadata
        case videoBuffer
        case audioBuffer
        // audioOriginal is excluded from Codable conformance
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decode(Metadata.self, forKey: .metadata)
        videoBuffer = try container.decodeIfPresent(Data.self, forKey: .videoBuffer)
        audioBuffer = try container.decodeIfPresent(Data.self, forKey: .audioBuffer)
        audioOriginal = nil  // not set during decoding
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metadata, forKey: .metadata)
        try container.encodeIfPresent(videoBuffer, forKey: .videoBuffer)
        try container.encodeIfPresent(audioBuffer, forKey: .audioBuffer)
        // audioOriginal is not encoded
    }
}

/// A class to capture screen and audio synchronously.
public class MediaCapture: NSObject, @unchecked Sendable {
    #if DEBUG
    public static let isTestEnvironment = ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] == "1"
    #endif

    private static let staticLogger = Logger(subsystem: "org.voibo.desktop-audio-capture", category: "MediaCapture")

    private let logger = Logger(subsystem: "org.voibo.desktop-audio-capture", category: "MediaCapture")
    private var stream: SCStream?
    private var streamOutput: MediaCaptureOutput?
    private let sampleBufferQueue = DispatchQueue(label: "org.voibo.MediaSampleBufferQueue", qos: .userInteractive)
    
    private var running: Bool = false
    private var mediaHandler: ((StreamableMediaData) -> Void)?
    private var errorHandler: ((String) -> Void)?
    
    public override init() {
        super.init()
    }
    
    // Adds an initializer to force mock mode for testing.
    internal init(forceMockCapture: Bool) {
        super.init()
    }
    
    /// An enumeration representing image formats.
    public enum ImageFormat: String {
        case jpeg = "jpeg"  // JPEG format (compressed, small size)
        case raw = "raw"    // Raw data (uncompressed, fast)
    }
    
    /// A structure representing image quality settings.
    public struct ImageQuality {
        /// Quality value (0.0-1.0, 1.0 is the highest quality)
        public let value: Float
        
        /// Default quality setting
        public static let standard = ImageQuality(value: 0.75)
        /// High quality setting
        public static let high = ImageQuality(value: 0.9)
        /// Low quality setting (e.g., when network bandwidth is limited)
        public static let low = ImageQuality(value: 0.5)
        
        /// Initializes with a specified quality value.
        public init(value: Float) {
            // Limits the value to the range of 0.0-1.0
            self.value = min(max(value, 0.0), 1.0)
        }
    }

    /// Capture quality settings.
    public enum CaptureQuality: Int {
        case high = 0    // Original size
        case medium = 1  // 75% scale
        case low = 2     // 50% scale
        
        var scale: Double {
            switch self {
                case .high: return 1.0
                case .medium: return 0.75
                case .low: return 0.5
            }
        }
    }
    
    /// An enumeration representing the type of capture target.
    public enum CaptureTargetType {
        case screen      // Entire screen
        case window      // Application window
        case all         // All
    }
    
    /// Starts capturing.
    /// - Parameters:
    ///   - target: The capture target.
    ///   - mediaHandler: Handler to receive synchronized media data.
    ///   - errorHandler: Handler to process errors (optional).
    ///   - framesPerSecond: Frames per second.
    ///   - quality: Capture quality.
    ///   - imageFormat: Format of captured images (jpeg, raw).
    ///   - imageQuality: Quality of image compression (0.0-1.0).
    ///   - audioSampleRate: Audio sampling rate in Hz (default: 48000).
    ///   - audioChannelCount: Number of audio channels (default: 2).
    ///   - isElectron: Whether the target is an Electron window (default: false).
    /// - Returns: Whether the capture started successfully.
    public func startCapture(
        target: MediaCaptureTarget,
        mediaHandler: @escaping (StreamableMediaData) -> Void,
        errorHandler: ((String) -> Void)? = nil,
        framesPerSecond: Double = 30.0,
        quality: CaptureQuality = .high,
        imageFormat: ImageFormat = .jpeg,
        imageQuality: ImageQuality = .standard,
        audioSampleRate: Int = 48000,
        audioChannelCount: Int = 2,
        isElectron: Bool = false
    ) async throws -> Bool {
        if running {
            return false
        }
        
        self.mediaHandler = mediaHandler
        self.errorHandler = errorHandler
        
        // Create and configure SCStreamConfiguration.
        let configuration = SCStreamConfiguration()
        
        // Audio is always enabled.
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        
        // Configure audio settings
        configuration.sampleRate = audioSampleRate
        configuration.channelCount = audioChannelCount
        
        // Frame rate settings.
        let captureVideo = framesPerSecond > 0
        
        // Configure resolution based on target type and quality
        if captureVideo {
            if framesPerSecond >= 1.0 {
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
            } else {
                let seconds = 1.0 / framesPerSecond
                configuration.minimumFrameInterval = CMTime(seconds: seconds, preferredTimescale: 600)
            }

            // Get scaling factor based on quality
            let scaleFactor = Double(quality.scale)

            if target.isWindow {
                // For window capture, use the window dimensions
                let windowWidth = Int(target.frame.width)
                let windowHeight = Int(target.frame.height)
                
                if windowWidth > 0 && windowHeight > 0 {
                    // Apply scaling based on quality
                    let scaledWidth = Int(Double(windowWidth) * scaleFactor)
                    let scaledHeight = Int(Double(windowHeight) * scaleFactor)
                    
                    // Always set dimensions for window capture to ensure correct size
                    configuration.width = scaledWidth
                    configuration.height = scaledHeight
                }
            } else {
                // For display capture, use the display dimensions
                let mainDisplayID = target.displayID > 0 ? target.displayID : CGMainDisplayID()
                let width = CGDisplayPixelsWide(mainDisplayID)
                let height = CGDisplayPixelsHigh(mainDisplayID)
                
                let scaledWidth = Int(Double(width) * scaleFactor)
                let scaledHeight = Int(Double(height) * scaleFactor)
                
                configuration.width = scaledWidth
                configuration.height = scaledHeight
            }
            
            // Cursor display settings
            configuration.showsCursor = true
        } 
        
        // Create ContentFilter.
        let filter = try await createContentFilter(from: target)
        
        // Create MediaCaptureOutput.
        let output = MediaCaptureOutput()
        output.mediaHandler = { [weak self] media in
            self?.mediaHandler?(media)
        }
        output.errorHandler = { [weak self] error in
            self?.errorHandler?(error)
        }

        // Configure audio settings
        output.configureAudioSettings(sampleRate: audioSampleRate, channelCount: audioChannelCount)

        // Configure image format and quality settings
        output.configureImageSettings(format: imageFormat, quality: imageQuality)
        
        // Set framesPerSecond.
        output.configureFrameRate(fps: framesPerSecond)
        
        // Store parameters for auto-reconnect
        output.storeReconnectionInfo(
            instance: self,
            target: target,
            framesPerSecond: framesPerSecond,
            quality: quality,
            imageFormat: imageFormat,
            imageQuality: imageQuality,
            audioSampleRate: audioSampleRate, 
            audioChannelCount: audioChannelCount,
            isElectron: isElectron
        )
        
        streamOutput = output
        
        // Create SCStream.
        stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        
        // Add stream output.
        if captureVideo {
            // Add screen capture only if the frame rate is greater than 0.
            try stream?.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleBufferQueue)
        }
        
        // Always add audio capture.
        try stream?.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleBufferQueue)
        
        // Start capturing.
        try await stream?.startCapture()
        
        running = true
        return true
    }
    
    /// Creates an `SCContentFilter` from a `MediaCaptureTarget`.
    private func createContentFilter(from target: MediaCaptureTarget) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        if target.isDisplay {
            guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
                throw NSError(domain: "MediaCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Specified display not found"])
            }
            
            return SCContentFilter(display: display, excludingWindows: [])
        } else if target.isWindow {
            guard let window = content.windows.first(where: { $0.windowID == target.windowID }) else {
                throw NSError(domain: "MediaCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Specified window not found"])
            }
            
            return SCContentFilter(desktopIndependentWindow: window)
        } else if let bundleID = target.bundleID {
            let appWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID }
            
            guard let window = appWindows.first else {
                throw NSError(domain: "MediaCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "Specified application window not found"])
            }
            
            return SCContentFilter(desktopIndependentWindow: window)
        }
        
        // Default: Main display.
        guard let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw NSError(domain: "MediaCapture", code: 4, userInfo: [NSLocalizedDescriptionKey: "No available display"])
        }
        
        return SCContentFilter(display: mainDisplay, excludingWindows: [])
    }
    
    /// Correct implementation including timeout handling.
    public class func availableCaptureTargets(ofType type: CaptureTargetType = .all) async throws -> [MediaCaptureTarget] {
        // Check for permission
        let hasPermission = await checkScreenCapturePermission()
        if !hasPermission {
            throw NSError(domain: "MediaCapture", code: 4, userInfo: [NSLocalizedDescriptionKey: "No screen capture permission"])
        }
        
        // Attempt to get actual targets with a timeout
        return try await withTimeout(seconds: 5.0) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            
            // Filter based on the specified type
            switch type {
            case .screen:
                return content.displays.map { MediaCaptureTarget.from(display: $0) }
            
            case .window:
                return content.windows.map { MediaCaptureTarget.from(window: $0) }
            
            case .all:
                let windows = content.windows.map { MediaCaptureTarget.from(window: $0) }
                let displays = content.displays.map { MediaCaptureTarget.from(display: $0) }
                return windows + displays
            }
        }
    }
    
    /// Stops capturing.
    public func stopCapture() async {
        if running {
            try? await stream?.stopCapture()
            stream = nil
            streamOutput = nil
            running = false
            mediaHandler = nil
        }
    }
    
    /// Stops capturing synchronously (for deinit).
    public func stopCaptureSync() {
        if running {
            let localStream = stream
            stream = nil
            streamOutput = nil
            
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                Task {
                    do {
                        try await localStream?.stopCapture()
                    } catch {
                        print("Capture stop error: \(error)")
                    }
                    semaphore.signal()
                }
            }
            
            _ = semaphore.wait(timeout: .now() + 2.0)
            running = false
            mediaHandler = nil
            errorHandler = nil
            
            print("Capture stopped synchronously")
        }
    }
    
    /// Returns whether it is currently capturing.
    public func isCapturing() -> Bool {
        return running
    }
    
    deinit {
        let capturePtr = self.stream
        Task { [weak capturePtr] in
            if let stream = capturePtr {
                try? await stream.stopCapture()
            }
        }
    }
    
    /// Implements timeout handling.
    private static func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            // Task to perform the actual operation
            group.addTask {
                return try await operation()
            }
            
            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: "MediaCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation timed out after \(seconds) seconds"])
            }
            
            // Returns the result of the first task that completes (success or error)
            let result = try await group.next()!
            group.cancelAll() // Cancel remaining tasks
            return result
        }
    }
    
    // Adds a method to check permissions
    public class func checkScreenCapturePermission() async -> Bool {
        #if DEBUG
        if isTestEnvironment {
            return true
        }
        #endif

        if ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] == "1" {
            staticLogger.debug("checkScreenCapturePermission: Use MOCK_CAPTURE")
            return true
        }

        do {
            // Check permissions with a timeout
            return try await withTimeout(seconds: 2.0) {
                do {
                    _ = try await SCShareableContent.current
                    return true
                } catch {
                    return false
                }
            }
        } catch {
            staticLogger.debug("Screen capture permission check failed: \(error.localizedDescription)")
            return false
        }
    }
}

/// A class that implements SCStreamOutput and SCStreamDelegate.
private class MediaCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let logger = Logger(subsystem: "org.voibo.desktop-audio-capture", category: "MediaCaptureOutput")
    
    private static let kYUV420vPixelFormat: UInt32 = 0x34323076

    var mediaHandler: ((StreamableMediaData) -> Void)?
    var errorHandler: ((String) -> Void)?
    
    // For auto-reconnection
    private weak var mediaCaptureInstance: MediaCapture?
    private var captureTarget: MediaCaptureTarget?
    private var captureParams: CaptureParameters?
    private var isReconnecting = false
    
    // Store capture parameters for reconnection
    struct CaptureParameters {
        let framesPerSecond: Double
        let quality: MediaCapture.CaptureQuality
        let imageFormat: MediaCapture.ImageFormat
        let imageQuality: MediaCapture.ImageQuality
        let audioSampleRate: Int
        let audioChannelCount: Int
        let isElectron: Bool
    }
    
    private let mediaDeliveryQueue = DispatchQueue(label: "org.voibo.MediaDeliveryQueue", qos: .userInteractive)
    
    // Buffered latest video frame.
    private var latestVideoFrame: (frame: FrameData, timestamp: Double)?
    
    // Lock used for synchronization.
    private let syncLock = NSLock()
    
    // Frame control properties
    private var targetFrameDuration: Double = 1.0/30.0  // Default 30fps
    private var lastFrameUpdateTime: Double = 0
    private var lastSentTime: Double = 0
    private var frameRateEnabled: Bool = true
    
    // Store reconnection info
    func storeReconnectionInfo(
        instance: MediaCapture,
        target: MediaCaptureTarget,
        framesPerSecond: Double,
        quality: MediaCapture.CaptureQuality,
        imageFormat: MediaCapture.ImageFormat,
        imageQuality: MediaCapture.ImageQuality,
        audioSampleRate: Int,
        audioChannelCount: Int,
        isElectron: Bool
    ) {
        self.mediaCaptureInstance = instance
        self.captureTarget = target
        self.captureParams = CaptureParameters(
            framesPerSecond: framesPerSecond,
            quality: quality,
            imageFormat: imageFormat,
            imageQuality: imageQuality,
            audioSampleRate: audioSampleRate,
            audioChannelCount: audioChannelCount,
            isElectron: isElectron
        )
    }
    
    // Method to configure frame rate
    func configureFrameRate(fps: Double) {
        if (fps <= 0) {
            frameRateEnabled = false
        } else {
            frameRateEnabled = true
            targetFrameDuration = 1.0/fps
        }
        lastFrameUpdateTime = 0
        lastSentTime = 0
    }

    // Adds methods to configure image format and quality settings
    private var imageFormat: MediaCapture.ImageFormat = .jpeg
    private var imageQuality: MediaCapture.ImageQuality = .standard
    func configureImageSettings(format: MediaCapture.ImageFormat, quality: MediaCapture.ImageQuality) {
        self.imageFormat = format
        self.imageQuality = quality
    }

    // Adds methods to configure audio settings
    private var desiredSampleRate: Int = 48000
    private var desiredChannelCount: Int = 2
    func configureAudioSettings(sampleRate: Int, channelCount: Int) {
        self.desiredSampleRate = sampleRate
        self.desiredChannelCount = channelCount
    }
    
    // Handle stream stopping with auto-reconnect
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Log detailed error information in debug mode
        #if DEBUG
        if let nsError = error as NSError {
            logger.error("""
                Stream stopped with error:
                - Domain: \(nsError.domain)
                - Code: \(nsError.code)
                - Description: \(nsError.localizedDescription)
                - UserInfo: \(nsError.userInfo)
                """)
        } else {
            logger.error("Stream stopped with error: \(error.localizedDescription)")
        }
        #endif
        
        // Notify through error handler
        errorHandler?("Capture stream stopped: \(error.localizedDescription)")
        
        // Check if already reconnecting to prevent multiple attempts
        guard !isReconnecting else { return }
        
        // Verify we have all required data for reconnection
        guard let captureInstance = mediaCaptureInstance,
              let target = captureTarget,
              let params = captureParams else {
            logger.error("Cannot reconnect: Missing capture parameters")
            return
        }
        
        // Set reconnecting flag
        isReconnecting = true
        
        #if DEBUG
        logger.notice("Initiating auto-reconnect for capture stream")
        #endif
        
        // Attempt immediate reconnection
        Task {
            do {
                #if DEBUG
                logger.notice("Reconnecting capture for \(target.isWindow ? "Window" : "Display") ID=\(target.isWindow ? target.windowID : target.displayID)")
                #endif
                
                // Restart capture with the same parameters
                let success = try await captureInstance.startCapture(
                    target: target,
                    mediaHandler: self.mediaHandler ?? { _ in },
                    errorHandler: self.errorHandler,
                    framesPerSecond: params.framesPerSecond,
                    quality: params.quality,
                    imageFormat: params.imageFormat,
                    imageQuality: params.imageQuality,
                    audioSampleRate: params.audioSampleRate,
                    audioChannelCount: params.audioChannelCount,
                    isElectron: params.isElectron
                )
                
                if (success) {
                    #if DEBUG
                    logger.notice("Capture stream reconnected successfully")
                    #endif
                } else {
                    logger.error("Failed to reconnect capture stream")
                    self.errorHandler?("Failed to reconnect capture stream")
                }
            } catch {
                logger.error("Error during capture reconnection: \(error.localizedDescription)")
                self.errorHandler?("Error during capture reconnection: \(error.localizedDescription)")
            }
            
            // Reset reconnection flag
            self.isReconnecting = false
        }
    }
    
    // Main processing method
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        
        let timestamp = CACurrentMediaTime()
        
        switch type {
        case .screen:
            // Video frame processing - but only save it
            handleVideoSampleBuffer(sampleBuffer, timestamp: timestamp)
            
        case .audio:
            // Audio data is always processed, attaching the latest video frame at that time
            handleAudioWithVideoFrame(sampleBuffer, timestamp: timestamp)
            
        default:
            logger.warning("Unknown sample buffer type received")
        }
    }
    
    // Video frames are only saved (not sent)
    private func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, timestamp: Double) {
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        
        // Frame rate control - determines frame update
        if !frameRateEnabled || timestamp - lastFrameUpdateTime >= targetFrameDuration {
            if let frameData = createFrameData(from: imageBuffer, timestamp: timestamp) {
                syncLock.lock()
                latestVideoFrame = (frameData, timestamp)
                syncLock.unlock()
                
                // Records the frame update time
                lastFrameUpdateTime = timestamp
            }
        }
    }
    
    private func handleAudioWithVideoFrame(_ sampleBuffer: CMSampleBuffer, timestamp: Double) {
        // Process audio data using AVAudioPCMBuffer (similar to AudioCapture)
        var pcmBuffer: AVAudioPCMBuffer?
        try? sampleBuffer.withAudioBufferList { audioBufferList, blockBuffer in
            guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
                  let format = AVAudioFormat(standardFormatWithSampleRate: description.mSampleRate, 
                                            channels: description.mChannelsPerFrame),
                  let samples = AVAudioPCMBuffer(pcmFormat: format, 
                                               bufferListNoCopy: audioBufferList.unsafePointer)
            else { return }
            
            pcmBuffer = samples
        }
        
        // Return if PCM buffer is not available
        guard let audioBuffer = pcmBuffer else { return }
        
        // Get current video frame
        syncLock.lock()
        let currentVideoFrame = latestVideoFrame
        syncLock.unlock()
        
        // Frame rate control
        let shouldSendVideo = frameRateEnabled && (timestamp - lastSentTime >= targetFrameDuration)
        
        // Process and send media through a unified path
        processAndSendMedia(
            audioBuffer: audioBuffer,
            videoFrame: shouldSendVideo ? currentVideoFrame?.frame : nil,
            timestamp: timestamp
        )
        
        // Update last sent time if video was included
        if shouldSendVideo {
            lastSentTime = timestamp
        }
    }

    // Unified media processing and sending method
    private func processAndSendMedia(audioBuffer: AVAudioPCMBuffer, videoFrame: FrameData?, timestamp: Double) {
        // Convert audio buffer to Data
        let audioData = convertAudioBufferToData(audioBuffer)
        
        // Process video data using existing logic
        var videoData: Data? = nil
        var videoInfo: StreamableMediaData.Metadata.VideoInfo? = nil
        
        if let frame = videoFrame {
            (videoData, videoInfo) = processVideoFrame((frame, timestamp))
        }
        
        // Create audio metadata
        let audioInfo = StreamableMediaData.Metadata.AudioInfo(
            sampleRate: audioBuffer.format.sampleRate,
            channelCount: Int(audioBuffer.format.channelCount),
            bytesPerFrame: audioBuffer.format.streamDescription.pointee.mBytesPerFrame,
            frameCount: UInt32(audioBuffer.frameLength)
        )
        
        // Create metadata
        let metadata = StreamableMediaData.Metadata(
            timestamp: timestamp,
            hasVideo: videoData != nil,
            hasAudio: true,
            videoInfo: videoInfo,
            audioInfo: audioInfo
        )
        
        // Create media data structure including the original audio buffer
        let streamableData = StreamableMediaData(
            metadata: metadata,
            videoBuffer: videoData,
            audioBuffer: audioData,
            audioOriginal: audioBuffer  // 元のAVAudioPCMBufferを保持
        )
        
        // Send on background queue for better performance
        mediaDeliveryQueue.async { [weak self] in
            self?.mediaHandler?(streamableData)
        }
    }

    // Helper method to convert AVAudioPCMBuffer to Data
    private func convertAudioBufferToData(_ buffer: AVAudioPCMBuffer) -> Data {
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        let bytesPerSample = 4 // Float32 = 4 bytes
        
        // Calculate total size from channel count and frame length
        let dataSize = channelCount * frameLength * bytesPerSample
        var audioData = Data(count: dataSize)
        
        // Copy data
        audioData.withUnsafeMutableBytes { rawBufferPointer in
            if let baseAddress = rawBufferPointer.baseAddress, 
               let floatChannelData = buffer.floatChannelData {
                
                // Copy data from each channel in interleaved format
                for frame in 0..<frameLength {
                    for channel in 0..<channelCount {
                        let offset = (frame * channelCount + channel) * bytesPerSample
                        let value = floatChannelData[channel][frame]
                        let valuePtr = baseAddress.advanced(by: offset).assumingMemoryBound(to: Float32.self)
                        valuePtr.pointee = value
                    }
                }
            }
        }
        
        return audioData
    }

    // Streamlined video processing helper method
    private func processVideoFrame(_ videoFrame: (frame: FrameData, timestamp: Double)) -> (Data?, StreamableMediaData.Metadata.VideoInfo?) {
        // Create video info structure
        let videoInfo = StreamableMediaData.Metadata.VideoInfo(
            width: videoFrame.frame.width,
            height: videoFrame.frame.height,
            bytesPerRow: videoFrame.frame.bytesPerRow,
            pixelFormat: videoFrame.frame.pixelFormat,
            format: imageFormat.rawValue,
            quality: imageFormat == .jpeg ? imageQuality.value : nil
        )

        // Convert to appropriate format
        if imageFormat == .jpeg {
            // Try JPEG conversion if requested
            if let imageBuffer = convertDataToImageBuffer(videoFrame.frame),
               let jpegData = createImageData(from: imageBuffer) {
                return (jpegData, videoInfo)
            }
        }
        
        // Return raw data as fallback
        return (videoFrame.frame.data, videoInfo)
    }

    // Single unified image data creation method
    private func createImageData(from imageBuffer: CVImageBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        
        // If raw format is requested, directly return the pixel buffer data
        if imageFormat == .raw {
            return createRawData(from: imageBuffer)
        }

        // For JPEG format, try to create JPEG data
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext(options: nil)
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            logger.error("Failed to create CGImage from CIImage")
            return createRawData(from: imageBuffer)
        }
        
        // JPEG encoding with NSBitmapImageRep
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        let jpegData = bitmapRep.representation(using: .jpeg, 
                                              properties: [.compressionFactor: imageQuality.value])
        
        if let data = jpegData, data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 {
            return data
        }
        
        // Fall back to raw data if JPEG encoding fails
        logger.warning("JPEG encoding failed - using raw data instead")
        return createRawData(from: imageBuffer)
    }

    // Simplified raw data extraction
    private func createRawData(from imageBuffer: CVImageBuffer) -> Data? {
        let height = CVPixelBufferGetHeight(imageBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else {
            logger.error("Failed to get pixel buffer base address")
            return nil
        }
        
        return Data(bytes: baseAddress, count: bytesPerRow * height)
    }
    
    // Helper method to generate CVImageBuffer from FrameData
    private func convertDataToImageBuffer(_ frameData: FrameData) -> CVImageBuffer? {
        let width = frameData.width
        let height = frameData.height
        
        var pixelBuffer: CVImageBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ] as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
        // Calculates the number of bytes to copy
        let bytesToCopy = min(frameData.bytesPerRow, bytesPerRow)
        
        // Copies row by row
        for y in 0..<height {
            let sourceOffset = y * frameData.bytesPerRow
            let destOffset = y * bytesPerRow
            
            frameData.data.withUnsafeBytes { srcBuffer in
                guard let srcPtr = srcBuffer.baseAddress else { return }
                
                memcpy(
                    baseAddress!.advanced(by: destOffset),
                    srcPtr.advanced(by: sourceOffset),
                    bytesToCopy
                )
            }
        }
        
        return pixelBuffer
    }
    
    private func createFrameData(from imageBuffer: CVImageBuffer, timestamp: Double) -> FrameData? {
        let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        
        // If it's a YUV format, convert to RGB
        if (pixelFormat == MediaCaptureOutput.kYUV420vPixelFormat) {
            CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
            
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            let context = CIContext(options: nil)
            
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
                logger.error("Failed to convert CIImage to CGImage")
                return nil
            }
            
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            let bitsPerComponent = 8
            let bytesPerRow = width * 4
            
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(data: nil,
                                         width: width,
                                         height: height,
                                         bitsPerComponent: bitsPerComponent,
                                         bytesPerRow: bytesPerRow,
                                         space: colorSpace,
                                         bitmapInfo: bitmapInfo.rawValue) else {
                logger.error("Failed to create CGContext")
                return nil
            }
            
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            
            guard let data = context.data else {
                logger.error("Failed to get bitmap data")
                return nil
            }
            
            let rgbData = Data(bytes: data, count: bytesPerRow * height)
            
            return FrameData(
                data: rgbData,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                timestamp: timestamp,
                pixelFormat: kCVPixelFormatType_32BGRA // Format after conversion
            )
        }
        // Use the original pixel data for RGB formats
        else {
            CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
            
            let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
            
            guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else {
                return nil
            }
            
            // Process the data appropriately
            let data: Data
            if bytesPerRow == width * 4 {
                // No padding
                data = Data(bytes: baseAddress, count: bytesPerRow * height)
            } else {
                // With padding, copy row by row
                var newData = Data(capacity: width * height * 4)
                for y in 0..<height {
                    let srcRow = baseAddress.advanced(by: y * bytesPerRow)
                    let actualRowBytes = min(width * 4, bytesPerRow)
                    newData.append(Data(bytes: srcRow, count: actualRowBytes))
                    
                    // Fill the rest with zeros if necessary
                    if actualRowBytes < width * 4 {
                        let padding = [UInt8](repeating: 0, count: width * 4 - actualRowBytes)
                        newData.append(contentsOf: padding)
                    }
                }
                data = newData
            }
            
            return FrameData(
                data: data,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                timestamp: timestamp,
                pixelFormat: pixelFormat
            )
        }
    }
}
