import Foundation
import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import OSLog

/// Represents a capture target (window or display).
public struct MediaCaptureTarget {
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
}

/// Frame data structure.
public struct FrameData {
    public let data: Data
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let timestamp: Double
    public let pixelFormat: UInt32
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
public struct StreamableMediaData: Codable {
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
}

/// A class to capture screen and audio synchronously.
public class MediaCapture: NSObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "org.voibo.desktop-audio-capture", category: "MediaCapture")
    private var stream: SCStream?
    private var streamOutput: MediaCaptureOutput?
    private let sampleBufferQueue = DispatchQueue(label: "org.voibo.MediaSampleBufferQueue", qos: .userInteractive)
    
    private var running: Bool = false
    private var mediaHandler: ((StreamableMediaData) -> Void)?
    private var errorHandler: ((String) -> Void)?
    private var mockTimer: Timer?
    
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
    
    /// キャプチャ対象の種類を表す列挙型
    public enum CaptureTargetType {
        case screen      // 画面全体
        case window      // アプリケーションウィンドウ
        case all         // すべて
    }
    
    /// Starts capturing.
    /// - Parameters:
    ///   - target: The capture target.
    ///   - mediaHandler: Handler to receive synchronized media data.
    ///   - errorHandler: Handler to process errors (optional).
    ///   - framesPerSecond: Frames per second.
    ///   - quality: Capture quality.
    /// - Returns: Whether the capture started successfully.
    public func startCapture(
        target: MediaCaptureTarget,
        mediaHandler: @escaping (StreamableMediaData) -> Void,
        errorHandler: ((String) -> Void)? = nil,
        framesPerSecond: Double = 30.0,
        quality: CaptureQuality = .high
    ) async throws -> Bool {
        // モックモードの確認
        if ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] == "1" {
            fputs("DEBUG: Using mock capture implementation\n", stderr)
            startMockCapture(mediaHandler: mediaHandler, framesPerSecond: framesPerSecond)
            return true
        }
        
        if running {
            return false
        }
        
        self.mediaHandler = mediaHandler
        self.errorHandler = errorHandler
        
        // Create and configure SCStreamConfiguration.
        let configuration = SCStreamConfiguration()
        
        // Audio settings (always enabled).
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        
        // Frame rate settings.
        let captureVideo = framesPerSecond > 0
        
        if captureVideo {
            if framesPerSecond >= 1.0 {
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
            } else {
                let seconds = 1.0 / framesPerSecond
                configuration.minimumFrameInterval = CMTime(seconds: seconds, preferredTimescale: 600)
            }
            
            // Quality settings (only for video capture).
            if quality != .high {
                let mainDisplayID = CGMainDisplayID()
                let width = CGDisplayPixelsWide(mainDisplayID)
                let height = CGDisplayPixelsHigh(mainDisplayID)
                
                let scaleFactor = Double(quality.scale)
                let scaledWidth = Int(Double(width) * scaleFactor)
                let scaledHeight = Int(Double(height) * scaleFactor)
                
                configuration.width = scaledWidth
                configuration.height = scaledHeight
            }
            
            // Cursor display settings (only for video capture).
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
    
    /// 正しいタイムアウト処理を含む実装
    public class func availableCaptureTargets(ofType type: CaptureTargetType = .all) async throws -> [MediaCaptureTarget] {
        // モックモードの確認
        if ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] == "1" {
            return mockCaptureTargets(type)
        }
        
        // 権限確認
        let hasPermission = await checkScreenCapturePermission()
        if !hasPermission {
            fputs("DEBUG: No screen capture permission, falling back to mock data\n", stderr)
            return mockCaptureTargets(type)
        }
        
        // タイムアウト付きで実際のターゲット取得を試みる
        do {
            return try await withTimeout(seconds: 5.0) {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                
                // 指定された種類に応じてフィルタリング
                switch type {
                case .screen:
                    // 画面のみを返す
                    return content.displays.map { MediaCaptureTarget.from(display: $0) }
                
                case .window:
                    // ウィンドウのみを返す
                    return content.windows.map { MediaCaptureTarget.from(window: $0) }
                
                case .all:
                    // すべて返す（従来の挙動）
                    let windows = content.windows.map { MediaCaptureTarget.from(window: $0) }
                    let displays = content.displays.map { MediaCaptureTarget.from(display: $0) }
                    return windows + displays
                }
            }
        } catch {
            fputs("DEBUG: Error getting capture targets: \(error.localizedDescription), falling back to mock data\n", stderr)
            return mockCaptureTargets(type)
        }
    }
    
    /// Stops capturing.
    public func stopCapture() async {
        if running {
            try? await stream?.stopCapture()
            stream = nil
            streamOutput = nil
            running = false
        }
    }
    
    /// Stops capturing synchronously (for deinit).
    public func stopCaptureSync() {
        if running {
            // Stop the capture stream.
            let localStream = stream  // Save to a local variable.
            
            stream = nil
            streamOutput = nil
            
            // Stop synchronously (use asynchronous API synchronously).
            let semaphore = DispatchSemaphore(value: 0)
            
            // Execute the stop process with a timeout.
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
            
            // Wait a maximum of 2 seconds (do not wait indefinitely).
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
    
    // タイムアウト処理を実装する関数
    private static func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            // 実際の操作を実行するタスク
            group.addTask {
                return try await operation()
            }
            
            // タイムアウト用タスク
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: "MediaCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation timed out after \(seconds) seconds"])
            }
            
            // 最初に完了したタスクの結果を返す（成功またはエラー）
            let result = try await group.next()!
            group.cancelAll() // 残りのタスクをキャンセル
            return result
        }
    }
    
    // 権限確認メソッドを追加
    public static func checkScreenCapturePermission() async -> Bool {
        do {
            // タイムアウト付きで権限確認
            return try await withTimeout(seconds: 2.0) {
                do {
                    _ = try await SCShareableContent.current
                    return true
                } catch {
                    return false
                }
            }
        } catch {
            fputs("DEBUG: Screen capture permission check failed: \(error.localizedDescription)\n", stderr)
            return false
        }
    }
    
    // 修正コード
    public static func mockCaptureTargets(_ type: CaptureTargetType) -> [MediaCaptureTarget] {
        fputs("DEBUG: Using mock capture targets\n", stderr)
        
        var targets = [MediaCaptureTarget]()
        
        // メインディスプレイを模したモック
        let mockDisplay = MediaCaptureTarget(
            windowID: 0,
            displayID: 1,
            title: "Mock Main Display",
            bundleID: nil,
            applicationName: nil,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        
        // ウィンドウを模したモック
        let mockWindow = MediaCaptureTarget(
            windowID: 1,
            displayID: 0,
            title: "Mock Window 1",
            bundleID: nil,
            applicationName: "Mock App 1",
            frame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )
        
        // 複数のモックウィンドウ (より多様なテストのため)
        let mockWindow2 = MediaCaptureTarget(
            windowID: 2,
            displayID: 0,
            title: "Mock Window 2",
            bundleID: "com.example.app2",
            applicationName: "Mock App 2",
            frame: CGRect(x: 300, y: 300, width: 1024, height: 768)
        )
        
        switch type {
        case .all:
            targets.append(mockWindow)
            targets.append(mockWindow2)
            targets.append(mockDisplay)
        case .screen:
            targets.append(mockDisplay)
        case .window:
            targets.append(mockWindow)
            targets.append(mockWindow2)
        }
        
        return targets
    }
    
    // モックキャプチャ用のプライベートメソッド
    private func startMockCapture(mediaHandler: @escaping (StreamableMediaData) -> Void, framesPerSecond: Double) {
        // キャプチャのクリーンアップ
        Task { await stopCapture() }
        
        // モックタイマーの設定
        let frameInterval = 1.0 / framesPerSecond
        mockTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { [weak self] _ in
            guard self != nil else { return }
            
            // モックビデオフレームの作成
            let width = 640
            let height = 480
            let bytesPerRow = width * 4
            var videoBuffer = Data(count: height * bytesPerRow)
            
            // オーディオデータの作成
            let channels = 2
            let frameCount = 480
            let sampleRate = 48000.0
            var audioBuffer = Data(count: channels * frameCount * MemoryLayout<Float32>.size)
            
            // メタデータの作成
            let videoInfo = StreamableMediaData.Metadata.VideoInfo(
                width: width, 
                height: height, 
                bytesPerRow: bytesPerRow,
                pixelFormat: UInt32(kCVPixelFormatType_32BGRA)
            )
            
            let audioInfo = StreamableMediaData.Metadata.AudioInfo(
                sampleRate: sampleRate, 
                channelCount: channels, 
                bytesPerFrame: UInt32(MemoryLayout<Float32>.size), 
                frameCount: UInt32(frameCount)
            )
            
            let timestamp = CACurrentMediaTime()
            let metadata = StreamableMediaData.Metadata(
                timestamp: timestamp,
                hasVideo: true,
                hasAudio: true,
                videoInfo: videoInfo,
                audioInfo: audioInfo
            )
            
            // 擬似データの作成 (単純なパターン)
            for i in 0..<videoBuffer.count/4 {
                let x = i % width
                let y = i / width
                let color: UInt32 = UInt32((x + y) % 255) | (UInt32((x * y) % 255) << 8) | (UInt32(x % 255) << 16) | (0xFF << 24)
                videoBuffer.withUnsafeMutableBytes { ptr in
                    ptr.storeBytes(of: color, toByteOffset: i * 4, as: UInt32.self)
                }
            }
            
            // サイン波のオーディオサンプルを生成
            let frequency: Float = 440.0 // A4音
            for i in 0..<frameCount {
                let time = Float(i) / Float(sampleRate)
                let value = sin(2.0 * .pi * frequency * time) * 0.5
                
                audioBuffer.withUnsafeMutableBytes { ptr in
                    // 左チャンネル
                    ptr.storeBytes(of: value, toByteOffset: i * MemoryLayout<Float32>.size * 2, as: Float32.self)
                    // 右チャンネル
                    ptr.storeBytes(of: value * 0.8, toByteOffset: (i * 2 + 1) * MemoryLayout<Float32>.size, as: Float32.self)
                }
            }
            
            // StreamableMediaDataを作成してハンドラーに渡す
            let mediaData = StreamableMediaData(
                metadata: metadata,
                videoBuffer: videoBuffer,
                audioBuffer: audioBuffer
            )
            
            mediaHandler(mediaData)
        }
    }
}

/// A class that implements SCStreamOutput and SCStreamDelegate.
private class MediaCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let logger = Logger(subsystem: "org.voibo.desktop-audio-capture", category: "MediaCaptureOutput")
    var mediaHandler: ((StreamableMediaData) -> Void)?
    var errorHandler: ((String) -> Void)?
    
    // Buffered latest video frame.
    private var latestVideoFrame: (frame: FrameData, timestamp: Double)?
    
    // Lock used for synchronization.
    private let syncLock = NSLock()
    
    // Synchronization time window (seconds) - frames and audio within this window are considered synchronized.
    private let syncTimeWindow: Double = 0.1
    
    // Timestamp of the last sent frame.
    private var lastSentFrameTimestamp: Double = 0
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        
        // Get the current timestamp.
        let timestamp = CACurrentMediaTime()
        
        // Process according to the sample buffer type.
        switch type {
        case .screen:
            handleVideoSampleBuffer(sampleBuffer, timestamp: timestamp)
        case .audio:
            handleAudioSampleBuffer(sampleBuffer, timestamp: timestamp)
        default:
            logger.warning("Unknown sample buffer type received")
        }
    }
    
    /// Processes video sample buffers.
    private func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, timestamp: Double) {
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        
        // Create frame data.
        if let frameData = createFrameData(from: imageBuffer, timestamp: timestamp) {
            syncLock.lock()
            
            // Update if there is no existing frame or if the new frame is newer.
            if latestVideoFrame == nil || timestamp > latestVideoFrame!.timestamp {
                latestVideoFrame = (frameData, timestamp)
                logger.debug("Updated latest video frame: timestamp=\(timestamp)")
            }
            
            syncLock.unlock()
        }
    }
    
    /// Processes audio sample buffers.
    private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, timestamp: Double) {
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              let blockBuffer = sampleBuffer.dataBuffer else {
            return
        }
        
        // Create AVAudioFormat from AudioStreamBasicDescription.
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: AVAudioChannelCount(asbd.mChannelsPerFrame),
            interleaved: asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        )
        
        guard let format = format else { return }
        
        // Get data from the block buffer.
        var audioData = Data()
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        // Get audio data from the block buffer.
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, 
                                   totalLengthOut: &length, dataPointerOut: &dataPointer)
        
        if let dataPointer = dataPointer, length > 0 {
            audioData = Data(bytes: dataPointer, count: length)
            
            // Synchronize immediately upon receiving audio.
            syncLock.lock()
            
            // Select the optimal video frame (audio priority).
            var videoData: Data? = nil
            var videoInfo: StreamableMediaData.Metadata.VideoInfo? = nil
            
            if let videoFrame = latestVideoFrame {
                let timeDifference = Swift.abs(videoFrame.timestamp - timestamp)
                
                // Use the latest frame regardless of the timestamp difference.
                videoData = videoFrame.frame.data
                videoInfo = StreamableMediaData.Metadata.VideoInfo(
                    width: videoFrame.frame.width,
                    height: videoFrame.frame.height,
                    bytesPerRow: videoFrame.frame.bytesPerRow,
                    pixelFormat: videoFrame.frame.pixelFormat
                )
                
                if timeDifference <= syncTimeWindow {
                    logger.debug("Found matching video frame: diff=\(timeDifference)")
                } else {
                    logger.debug("Using closest video frame: diff=\(timeDifference)")
                }
            }
            
            // Create AudioInfo.
            let audioInfo = StreamableMediaData.Metadata.AudioInfo(
                sampleRate: format.sampleRate,
                channelCount: Int(format.channelCount),
                bytesPerFrame: format.streamDescription.pointee.mBytesPerFrame,
                frameCount: 0 //samples.frameLength
            )
            
            // Create metadata.
            let metadata = StreamableMediaData.Metadata(
                timestamp: timestamp,
                hasVideo: videoData != nil,
                hasAudio: true,
                videoInfo: videoInfo,
                audioInfo: audioInfo
            )
            
            // Create a streamable data structure for Node.js.
            let streamableData = StreamableMediaData(
                metadata: metadata,
                videoBuffer: videoData,
                audioBuffer: audioData
            )
            
            syncLock.unlock()
            
            // Ensure UI updates are performed on the main thread.
            let capturedStreamableData = streamableData // Copy to a local variable.
            
            // Call the handler on the main thread.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.mediaHandler?(capturedStreamableData)
            }
            
            // Record that it has been processed.
            lastSentFrameTimestamp = timestamp
        }
    }
    
    /// Creates FrameData by retrieving image data from CMSampleBuffer.
    private func createFrameData(from imageBuffer: CVImageBuffer, timestamp: Double) -> FrameData? {
        let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        
        // If it's a YUV format, convert to RGB.
        if (pixelFormat == 0x34323076) { // '420v' YUV format
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
        // Use the original pixel data (RGB format).
        else {
            CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
            
            let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
            
            guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else {
                return nil
            }
            
            // Process the data appropriately.
            let data: Data
            if bytesPerRow == width * 4 {
                // No padding.
                data = Data(bytes: baseAddress, count: bytesPerRow * height)
            } else {
                // With padding, copy row by row.
                var newData = Data(capacity: width * height * 4)
                for y in 0..<height {
                    let srcRow = baseAddress.advanced(by: y * bytesPerRow)
                    let actualRowBytes = min(width * 4, bytesPerRow)
                    newData.append(Data(bytes: srcRow, count: actualRowBytes))
                    
                    // Fill the rest with zeros if necessary.
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
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        errorHandler?("Capture stream stopped: \(error.localizedDescription)")
    }
}
