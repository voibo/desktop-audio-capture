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
        // windowIDとdisplayIDの組み合わせでユニークIDを生成
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
    
    // Hashableの実装
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(windowID)
        hasher.combine(displayID)
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
            public let format: String  // "raw" または "jpeg"
            public let quality: Float? // JPEG品質設定値（0.0-1.0）
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
    private static let staticLogger = Logger(subsystem: "org.voibo.desktop-audio-capture", category: "MediaCapture")

    private let logger = Logger(subsystem: "org.voibo.desktop-audio-capture", category: "MediaCapture")
    private var stream: SCStream?
    private var streamOutput: MediaCaptureOutput?
    private let sampleBufferQueue = DispatchQueue(label: "org.voibo.MediaSampleBufferQueue", qos: .userInteractive)
    
    private var running: Bool = false
    private var mediaHandler: ((StreamableMediaData) -> Void)?
    private var errorHandler: ((String) -> Void)?
    private var mockTimer: Timer?
    private var audioTimer: Timer?  // 追加: オーディオ専用タイマー
    
    public override init() {
        super.init()
    }
    
    // テスト用にモックモードを強制設定するイニシャライザを追加
    internal init(forceMockCapture: Bool) {
        super.init()
    }
    
    /// 画像形式を表す列挙型
    public enum ImageFormat: String {
        case jpeg = "jpeg"  // JPEGフォーマット（圧縮、小さいサイズ）
        case raw = "raw"    // 生データ（非圧縮、高速）
    }
    
    /// 画像品質設定を表す構造体
    public struct ImageQuality {
        /// 品質値（0.0〜1.0、1.0が最高品質）
        public let value: Float
        
        /// デフォルト品質設定
        public static let standard = ImageQuality(value: 0.75)
        /// 高品質設定
        public static let high = ImageQuality(value: 0.9)
        /// 低品質設定（ネットワーク帯域が制限されている場合など）
        public static let low = ImageQuality(value: 0.5)
        
        /// 品質値を指定して初期化
        public init(value: Float) {
            // 値を0.0〜1.0の範囲に制限
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
    ///   - imageFormat: Format of captured images (jpeg, raw).
    ///   - imageQuality: Quality of image compression (0.0-1.0).
    /// - Returns: Whether the capture started successfully.
    public func startCapture(
        target: MediaCaptureTarget,
        mediaHandler: @escaping (StreamableMediaData) -> Void,
        errorHandler: ((String) -> Void)? = nil,
        framesPerSecond: Double = 30.0,
        quality: CaptureQuality = .high,
        imageFormat: ImageFormat = .jpeg,
        imageQuality: ImageQuality = .standard
    ) async throws -> Bool {
        if running {
            return false
        }
        
        self.mediaHandler = mediaHandler
        self.errorHandler = errorHandler
        
        // Create and configure SCStreamConfiguration.
        let configuration = SCStreamConfiguration()
        
        // Audio sealways enabled).s (always enabled).
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

            // Quality settings
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

        // 画像フォーマットと品質の設定を追加
        output.configureImageSettings(format: imageFormat, quality: imageQuality)
        
        // Set framesPerSecond.
        output.configureFrameRate(fps: framesPerSecond)
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
        // 権限確認
        let hasPermission = await checkScreenCapturePermission()
        if !hasPermission {
            throw NSError(domain: "MediaCapture", code: 4, userInfo: [NSLocalizedDescriptionKey: "No screen capture permission"])
        }
        
        // タイムアウト付きで実際のターゲット取得を試みる
        return try await withTimeout(seconds: 5.0) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            
            // 指定された種類に応じてフィルタリング
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
            if let timer = mockTimer {
                timer.invalidate()
                mockTimer = nil
            }
            
            if let timer = audioTimer {  // 追加: audioTimerの停止処理
                timer.invalidate()
                audioTimer = nil
            }
            
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
            if let timer = mockTimer {
                timer.invalidate()
                mockTimer = nil
            }
            
            if let timer = audioTimer {  // 追加: audioTimerの停止処理
                timer.invalidate()
                audioTimer = nil
            }
            
            // 以下は既存のコード
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
            staticLogger.debug("Screen capture permission check failed: \(error.localizedDescription)")  // インスタンスloggerを静的loggerに変更
            return false
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
    
    // フレーム制御プロパティ
    private var targetFrameDuration: Double = 1.0/30.0  // デフォルト30fps
    private var lastFrameUpdateTime: Double = 0
    private var lastSentTime: Double = 0
    private var frameRateEnabled: Bool = true
    
    // フレームレート設定メソッド
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

    // 画像フォーマットと品質の設定メソッドを追加
    private var imageFormat: MediaCapture.ImageFormat = .jpeg
    private var imageQuality: MediaCapture.ImageQuality = .standard
    
    func configureImageSettings(format: MediaCapture.ImageFormat, quality: MediaCapture.ImageQuality) {
        self.imageFormat = format
        self.imageQuality = quality
    }

    // メインの処理メソッド
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        
        let timestamp = CACurrentMediaTime()
        
        switch type {
        case .screen:
            // ビデオフレームの処理 - ただし保存のみ
            handleVideoSampleBuffer(sampleBuffer, timestamp: timestamp)
            
        case .audio:
            // 音声データは常に処理し、その時点の最新ビデオフレームを添付
            handleAudioWithVideoFrame(sampleBuffer, timestamp: timestamp)
            
        default:
            logger.warning("Unknown sample buffer type received")
        }
    }
    
    // ビデオフレームは保存するだけ（送信はしない）
    private func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, timestamp: Double) {
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        
        // フレームレート制御 - フレーム更新の判断
        if !frameRateEnabled || timestamp - lastFrameUpdateTime >= targetFrameDuration {
            if let frameData = createFrameData(from: imageBuffer, timestamp: timestamp) {
                syncLock.lock()
                latestVideoFrame = (frameData, timestamp)
                syncLock.unlock()
                
                // フレーム更新時間の記録
                lastFrameUpdateTime = timestamp
            }
        }
    }
    
    // 音声データ処理時に最新のビデオフレームを適用するメソッドを修正
    private func handleAudioWithVideoFrame(_ sampleBuffer: CMSampleBuffer, timestamp: Double) {
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              let blockBuffer = sampleBuffer.dataBuffer else {
            return
        }
        
        // 音声データの抽出
        var audioData = Data()
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, 
                                   totalLengthOut: &length, dataPointerOut: &dataPointer)
        
        if let dataPointer = dataPointer, length > 0 {
            audioData = Data(bytes: dataPointer, count: length)
            
            // 現在のビデオフレームを取得
            syncLock.lock()
            let currentVideoFrame = latestVideoFrame
            syncLock.unlock()
            
            // フレームレート制御 - 送信判断（修正版）
            // タイムスタンプ比較を削除し、純粋に時間間隔のみで判定
            let shouldSendVideo = frameRateEnabled && 
                                 (timestamp - lastSentTime >= targetFrameDuration)
            
            // 音声データは常に送信、ビデオデータはフレームレート制御に従って添付
            var videoData: Data? = nil
            var videoInfo: StreamableMediaData.Metadata.VideoInfo? = nil
            
            if shouldSendVideo, let videoFrame = currentVideoFrame {
                // JPEG形式に変換する
                if let imageBuffer = convertDataToImageBuffer(videoFrame.frame) {
                    // 設定された画像フォーマットと品質を使用
                    if let imageData = createImageData(
                        from: imageBuffer,
                        format: imageFormat.rawValue,
                        quality: imageQuality.value
                    ) {
                        videoData = imageData
                        videoInfo = StreamableMediaData.Metadata.VideoInfo(
                            width: videoFrame.frame.width,
                            height: videoFrame.frame.height,
                            bytesPerRow: videoFrame.frame.bytesPerRow,
                            pixelFormat: videoFrame.frame.pixelFormat,
                            format: imageFormat.rawValue,
                            quality: imageQuality.value
                        )
                    } else {
                        // 変換失敗時のフォールバック処理
                        videoData = videoFrame.frame.data
                        videoInfo = StreamableMediaData.Metadata.VideoInfo(
                            width: videoFrame.frame.width,
                            height: videoFrame.frame.height,
                            bytesPerRow: videoFrame.frame.bytesPerRow,
                            pixelFormat: videoFrame.frame.pixelFormat,
                            format: "raw",
                            quality: nil
                        )
                    }
                } else {
                    // JPEG変換失敗時は生データを使用
                    videoData = videoFrame.frame.data
                    videoInfo = StreamableMediaData.Metadata.VideoInfo(
                        width: videoFrame.frame.width,
                        height: videoFrame.frame.height,
                        bytesPerRow: videoFrame.frame.bytesPerRow,
                        pixelFormat: videoFrame.frame.pixelFormat,
                        format: "raw",
                        quality: nil
                    )
                }
                
                // 送信したフレームのタイムスタンプを記録（修正版）
                // フレームのタイムスタンプではなく現在時刻を使用
                lastSentTime = timestamp
            }
            
            // AudioInfo作成時の型変換エラー修正
            let audioInfo = StreamableMediaData.Metadata.AudioInfo(
                sampleRate: asbd.mSampleRate,
                channelCount: Int(asbd.mChannelsPerFrame),
                bytesPerFrame: UInt32(asbd.mBytesPerFrame),  // UInt32に明示的に型変換
                frameCount: UInt32(length / Int(asbd.mBytesPerFrame))
            )
            
            // 統合メタデータ作成
            let metadata = StreamableMediaData.Metadata(
                timestamp: timestamp,
                hasVideo: videoData != nil,
                hasAudio: true,
                videoInfo: videoInfo,
                audioInfo: audioInfo
            )
            
            // 単一のデータ構造で送信
            let streamableData = StreamableMediaData(
                metadata: metadata,
                videoBuffer: videoData,
                audioBuffer: audioData
            )
            
            // メインスレッドでハンドラを呼び出し
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.mediaHandler?(streamableData)
            }
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
    
    // 画像変換用のヘルパーメソッドを修正
    private func createJPEGData(from imageBuffer: CVImageBuffer, format: String = "jpeg", quality: Float = 0.75) -> Data? {
        // JPEGエンコードを試みる
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        
        // 高速パスとして、変換不要ならすぐにrawデータを返す
        if format != "jpeg" {
            return createRawData(from: imageBuffer)
        }
        
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext(options: nil)
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            print("ERROR: Failed to create CGImage from CIImage - falling back to raw data")
            return createRawData(from: imageBuffer)
        }
        
        // NSBitmapImageRepでJPEGエンコード
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        
        if let data = jpegData {
            // ヘッダー確認
            if data.count >= 2 && data[0] == 0xFF && data[1] == 0xD8 {
                return data
            }
            // JPEGとして無効な場合はrawデータを返す
            print("WARNING: Invalid JPEG data generated, using raw data instead")
            return createRawData(from: imageBuffer)
        } else {
            print("ERROR: JPEG encoding failed - using raw data")
            return createRawData(from: imageBuffer)
        }
    }
    
    private func createImageData(from imageBuffer: CVImageBuffer, format: String, quality: Float) -> Data? {
        // JPEGエンコード用の既存メソッドを流用
        if format == "jpeg" {
            return createJPEGData(from: imageBuffer, format: format, quality: quality)
        } else {
            // RAW形式の場合はビットマップデータを返す
            return createRawData(from: imageBuffer)
        }
    }
    
    // RAW形式のデータを生成（元のピクセルバッファを直接利用）
    private func createRawData(from imageBuffer: CVImageBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        
        // 元のピクセルバッファから直接データを取得
        _ = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else {
            print("ERROR: Failed to get pixel buffer base address")
            return nil
        }
        
        // 元のピクセルバッファデータをそのまま返す
        let rawData = Data(bytes: baseAddress, count: bytesPerRow * height)
        print("Using raw pixel buffer data: \(rawData.count) bytes")
        return rawData
    }
    
    // FrameDataからCVImageBufferを生成するヘルパーメソッド
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
        
        // コピーするバイト数を計算
        let bytesToCopy = min(frameData.bytesPerRow, bytesPerRow)
        
        // 1行ずつコピー
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
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        errorHandler?("Capture stream stopped: \(error.localizedDescription)")
    }
}
