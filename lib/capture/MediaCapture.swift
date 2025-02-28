import Foundation
import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import OSLog

/// キャプチャターゲット（ウィンドウまたはディスプレイ）を表す構造体
public struct MediaCaptureTarget {
    /// ウィンドウID
    public let windowID: CGWindowID
    
    /// ディスプレイID
    public let displayID: CGDirectDisplayID
    
    /// タイトル
    public let title: String?
    
    /// バンドルID
    public let bundleID: String?
    
    /// フレーム
    public let frame: CGRect
    
    /// アプリケーション名
    public let applicationName: String?
    
    /// ウィンドウかどうか
    public var isWindow: Bool { windowID > 0 }
    
    /// ディスプレイかどうか
    public var isDisplay: Bool { displayID > 0 }
    
    /// 初期化
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
    
    /// SCWindowからMediaCaptureTargetを作成
    public static func from(window: SCWindow) -> MediaCaptureTarget {
        return MediaCaptureTarget(
            windowID: window.windowID,
            title: window.title,
            bundleID: window.owningApplication?.bundleIdentifier,
            applicationName: window.owningApplication?.applicationName,
            frame: window.frame
        )
    }
    
    /// SCDisplayからMediaCaptureTargetを作成
    public static func from(display: SCDisplay) -> MediaCaptureTarget {
        return MediaCaptureTarget(
            displayID: display.displayID,
            title: "Display \(display.displayID)",
            frame: CGRect(x: 0, y: 0, width: display.width, height: display.height)
        )
    }
}

/// フレームデータ構造体
public struct FrameData {
    public let data: Data
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let timestamp: Double
    public let pixelFormat: UInt32  // Int から UInt32 に変更
}

/// 同期されたメディアデータを保持する構造体
public struct SynchronizedMedia {
    public let frame: FrameData?
    public let audio: AVAudioPCMBuffer?
    public let timestamp: Double
    
    public var hasFrame: Bool { return frame != nil }
    public var hasAudio: Bool { return audio != nil }
    public var isComplete: Bool { return hasFrame && hasAudio }
}

// Node.jsと連携するためのシンプルなデータ構造
public struct StreamableMediaData: Codable {
    // メタデータ（JSONシリアライズ可能）
    public struct Metadata: Codable {
        public let timestamp: Double
        public let hasVideo: Bool
        public let hasAudio: Bool
        
        // ビデオメタデータ
        public struct VideoInfo: Codable {
            public let width: Int
            public let height: Int
            public let bytesPerRow: Int
            public let pixelFormat: UInt32
        }
        
        // オーディオメタデータ
        public struct AudioInfo: Codable {
            public let sampleRate: Double
            public let channelCount: Int
            public let bytesPerFrame: UInt32
            public let frameCount: UInt32
        }
        
        public let videoInfo: VideoInfo?
        public let audioInfo: AudioInfo?
    }
    
    // メタデータ（JSONとして処理可能）
    public let metadata: Metadata
    
    // ビデオデータ（Raw Bufferとして転送）
    public let videoBuffer: Data?
    
    // オーディオデータ（Raw Bufferとして転送）
    public let audioBuffer: Data?
}

/// 画面とオーディオを同期してキャプチャするクラス
public class MediaCapture: NSObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "org.voibo.desktop-audio-capture", category: "MediaCapture")
    private var stream: SCStream?
    private var streamOutput: MediaCaptureOutput?
    private let sampleBufferQueue = DispatchQueue(label: "org.voibo.MediaSampleBufferQueue", qos: .userInteractive)
    
    private var running: Bool = false
    private var mediaHandler: ((StreamableMediaData) -> Void)?
    private var errorHandler: ((String) -> Void)?
    
    /// キャプチャ品質設定
    public enum CaptureQuality: Int {
        case high = 0    // 元のサイズ
        case medium = 1  // 75%スケール
        case low = 2     // 50%スケール
        
        var scale: Double {
            switch self {
                case .high: return 1.0
                case .medium: return 0.75
                case .low: return 0.5
            }
        }
    }
    
    /// キャプチャを開始する
    /// - Parameters:
    ///   - target: キャプチャ対象
    ///   - mediaHandler: 同期されたメディアデータを受け取るハンドラ
    ///   - errorHandler: エラーを処理するハンドラ（オプション）
    ///   - framesPerSecond: 1秒あたりのフレーム数
    ///   - quality: キャプチャ品質
    /// - Returns: キャプチャの開始が成功したかどうか
    public func startCapture(
        target: MediaCaptureTarget,
        mediaHandler: @escaping (StreamableMediaData) -> Void,
        errorHandler: ((String) -> Void)? = nil,
        framesPerSecond: Double = 30.0,
        quality: CaptureQuality = .high
    ) async throws -> Bool {
        if running {
            return false
        }
        
        self.mediaHandler = mediaHandler
        self.errorHandler = errorHandler
        
        // SCStreamConfigurationの作成と設定
        let configuration = SCStreamConfiguration()
        
        // オーディオ設定（常に有効）
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        
        // フレームレート設定
        let captureVideo = framesPerSecond > 0
        
        if captureVideo {
            if framesPerSecond >= 1.0 {
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
            } else {
                let seconds = 1.0 / framesPerSecond
                configuration.minimumFrameInterval = CMTime(seconds: seconds, preferredTimescale: 600)
            }
            
            // 品質設定（ビデオキャプチャ時のみ）
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
            
            // カーソル表示設定（ビデオキャプチャ時のみ）
            configuration.showsCursor = true
        }
        
        // ContentFilterの作成
        let filter = try await createContentFilter(from: target)
        
        // MediaCaptureOutputの作成
        let output = MediaCaptureOutput()
        output.mediaHandler = { [weak self] media in
            self?.mediaHandler?(media)
        }
        output.errorHandler = { [weak self] error in
            self?.errorHandler?(error)
        }
        
        streamOutput = output
        
        // SCStreamの作成
        stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        
        // ストリーム出力の追加
        if captureVideo {
            // フレームレートが0より大きい場合のみ画面キャプチャを追加
            try stream?.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleBufferQueue)
        }
        
        // 音声キャプチャは常に追加
        try stream?.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleBufferQueue)
        
        // キャプチャ開始
        try await stream?.startCapture()
        
        running = true
        return true
    }
    
    /// MediaCaptureTargetからSCContentFilterを作成する
    private func createContentFilter(from target: MediaCaptureTarget) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        if target.isDisplay {
            guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
                throw NSError(domain: "MediaCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "指定されたディスプレイが見つかりません"])
            }
            
            return SCContentFilter(display: display, excludingWindows: [])
        } else if target.isWindow {
            guard let window = content.windows.first(where: { $0.windowID == target.windowID }) else {
                throw NSError(domain: "MediaCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "指定されたウィンドウが見つかりません"])
            }
            
            return SCContentFilter(desktopIndependentWindow: window)
        } else if let bundleID = target.bundleID {
            let appWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID }
            
            guard let window = appWindows.first else {
                throw NSError(domain: "MediaCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "指定されたアプリケーションのウィンドウが見つかりません"])
            }
            
            return SCContentFilter(desktopIndependentWindow: window)
        }
        
        // デフォルト: メインディスプレイ
        guard let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw NSError(domain: "MediaCapture", code: 4, userInfo: [NSLocalizedDescriptionKey: "利用可能なディスプレイがありません"])
        }
        
        return SCContentFilter(display: mainDisplay, excludingWindows: [])
    }
    
    /// 利用可能なウィンドウを取得する
    public class func availableWindows() async throws -> [MediaCaptureTarget] {
        // テスト環境でのモック対応
        if ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] == "1" {
            return [
                MediaCaptureTarget(
                    windowID: 1,
                    title: "Mock Window 1",
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600)
                ),
                MediaCaptureTarget(
                    windowID: 2,
                    title: "Mock Window 2",
                    frame: CGRect(x: 100, y: 100, width: 800, height: 600)
                )
            ]
        }
        
        // 実際の実装
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        let windows = content.windows.map { MediaCaptureTarget.from(window: $0) }
        let displays = content.displays.map { MediaCaptureTarget.from(display: $0) }
        
        return windows + displays
    }
    
    /// キャプチャを停止する
    public func stopCapture() async {
        if running {
            try? await stream?.stopCapture()
            stream = nil
            streamOutput = nil
            running = false
        }
    }
    
    /// 同期的にキャプチャを停止する（deinit用）
    public func stopCaptureSync() {
        if running {
            // キャプチャストリームを停止
            let localStream = stream  // ローカル変数に保存
            
            stream = nil
            streamOutput = nil
            
            // 同期的に停止（非同期APIを同期的に使用）
            let semaphore = DispatchSemaphore(value: 0)
            
            // タイムアウト付きで停止処理を実行
            DispatchQueue.global(qos: .userInitiated).async {
                Task {
                    do {
                        try await localStream?.stopCapture()
                    } catch {
                        print("キャプチャ停止エラー: \(error)")
                    }
                    semaphore.signal()
                }
            }
            
            // 最大2秒待機（無限に待機しない）
            _ = semaphore.wait(timeout: .now() + 2.0)
            
            running = false
            mediaHandler = nil
            errorHandler = nil
            
            print("キャプチャを同期的に停止しました")
        }
    }
    
    /// 現在キャプチャ中かどうかを返す
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
}

/// SCStreamOutputとSCStreamDelegateを実装するクラス
private class MediaCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let logger = Logger(subsystem: "org.voibo.desktop-audio-capture", category: "MediaCaptureOutput")
    var mediaHandler: ((StreamableMediaData) -> Void)?
    var errorHandler: ((String) -> Void)?
    
    // バッファリングされた最新のビデオフレーム
    private var latestVideoFrame: (frame: FrameData, timestamp: Double)?
    
    // 同期に使用するロック
    private let syncLock = NSLock()
    
    // 同期タイムウィンドウ（秒）- このウィンドウ内のフレームとオーディオを同期とみなす
    private let syncTimeWindow: Double = 0.1
    
    // 最後に送信したフレームのタイムスタンプ
    private var lastSentFrameTimestamp: Double = 0
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        
        // 現在のタイムスタンプを取得
        let timestamp = CACurrentMediaTime()
        
        // サンプルバッファのタイプに応じて処理
        switch type {
        case .screen:
            handleVideoSampleBuffer(sampleBuffer, timestamp: timestamp)
        case .audio:
            handleAudioSampleBuffer(sampleBuffer, timestamp: timestamp)
        default:
            logger.warning("Unknown sample buffer type received")
        }
    }
    
    /// ビデオサンプルバッファを処理する
    private func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, timestamp: Double) {
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        
        // フレームデータの作成
        if let frameData = createFrameData(from: imageBuffer, timestamp: timestamp) {
            syncLock.lock()
            
            // 既存のフレームがなければ、または新しいフレームのほうが新しければ、更新
            if latestVideoFrame == nil || timestamp > latestVideoFrame!.timestamp {
                latestVideoFrame = (frameData, timestamp)
                logger.debug("Updated latest video frame: timestamp=\(timestamp)")
            }
            
            syncLock.unlock()
        }
    }
    
    /// オーディオサンプルバッファを処理する
    private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, timestamp: Double) {
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              let blockBuffer = sampleBuffer.dataBuffer else {
            return
        }
        
        // AudioStreamBasic記述からAVAudioFormatを作成
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: AVAudioChannelCount(asbd.mChannelsPerFrame),
            interleaved: asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        )
        
        guard let format = format else { return }
        
        // ブロックバッファからデータを取得
        var audioData = Data()
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        // ブロックバッファからオーディオデータを取得
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, 
                                   totalLengthOut: &length, dataPointerOut: &dataPointer)
        
        if let dataPointer = dataPointer, length > 0 {
            audioData = Data(bytes: dataPointer, count: length)
            
            // 以下、既存のコードと同様にメタデータとストリーム可能なデータを作成...
            // オーディオデータをNodeJSが理解できる形式に変換
            //guard let audioData = convertAudioBufferToData(samples) else {
            //    logger.error("Failed to convert audio buffer to data")
            //    return
            //}
            
            // オーディオ受信時にすぐに同期処理
            syncLock.lock()
            
            // 最適なビデオフレームを選択（オーディオ優先）
            var videoData: Data? = nil
            var videoInfo: StreamableMediaData.Metadata.VideoInfo? = nil
            
            if let videoFrame = latestVideoFrame {
                let timeDifference = abs(videoFrame.timestamp - timestamp)
                
                // タイムスタンプの差に関わらず最新フレームを使用
                videoData = videoFrame.frame.data
                videoInfo = StreamableMediaData.Metadata.VideoInfo(
                    width: videoFrame.frame.width,
                    height: videoFrame.frame.height,
                    bytesPerRow: videoFrame.frame.bytesPerRow,
                    pixelFormat: videoFrame.frame.pixelFormat  // Int への変換は不要
                )
                
                if timeDifference <= syncTimeWindow {
                    logger.debug("Found matching video frame: diff=\(timeDifference)")
                } else {
                    logger.debug("Using closest video frame: diff=\(timeDifference)")
                }
            }
            
            // Audio情報の作成
            let audioInfo = StreamableMediaData.Metadata.AudioInfo(
                sampleRate: format.sampleRate,
                channelCount: Int(format.channelCount),
                bytesPerFrame: format.streamDescription.pointee.mBytesPerFrame,
                frameCount: 0 //samples.frameLength
            )
            
            // メタデータを作成
            let metadata = StreamableMediaData.Metadata(
                timestamp: timestamp,
                hasVideo: videoData != nil,
                hasAudio: true,
                videoInfo: videoInfo,
                audioInfo: audioInfo
            )
            
            // Node.js用のストリーム可能なデータ構造を作成
            let streamableData = StreamableMediaData(
                metadata: metadata,
                videoBuffer: videoData,
                audioBuffer: audioData
            )
            
            syncLock.unlock()
            
            // UIの更新はメインスレッドで確実に実行するように修正
            let capturedStreamableData = streamableData // ローカル変数にコピー
            
            // メインスレッドでハンドラを呼び出す
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.mediaHandler?(capturedStreamableData)
            }
            
            // 処理したことを記録
            lastSentFrameTimestamp = timestamp
        }
    }
    
    // CMSampleBufferから画像データを取得してFrameDataを作成
    private func createFrameData(from imageBuffer: CVImageBuffer, timestamp: Double) -> FrameData? {
        let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        
        // YUVフォーマットの場合、RGBに変換
        if pixelFormat == 0x34323076 { // '420v' YUV format
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
                pixelFormat: kCVPixelFormatType_32BGRA // 変換後のフォーマット
            )
        }
        // 元のピクセルデータを使用（RGB形式）
        else {
            CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
            
            let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
            
            guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else {
                return nil
            }
            
            // データを適切に処理
            let data: Data
            if bytesPerRow == width * 4 {
                // パディングなし
                data = Data(bytes: baseAddress, count: bytesPerRow * height)
            } else {
                // パディングあり、行ごとにコピー
                var newData = Data(capacity: width * height * 4)
                for y in 0..<height {
                    let srcRow = baseAddress.advanced(by: y * bytesPerRow)
                    let actualRowBytes = min(width * 4, bytesPerRow)
                    newData.append(Data(bytes: srcRow, count: actualRowBytes))
                    
                    // 必要に応じて残りをゼロで埋める
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
