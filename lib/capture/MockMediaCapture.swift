import Foundation
import OSLog
import CoreGraphics
import AVFoundation
import ScreenCaptureKit

/// モックキャプチャ実装のためのクラス
public class MockMediaCapture: MediaCapture, @unchecked Sendable {
    private let logger = Logger(subsystem: "org.voibo.desktop-audio-capture", category: "MockMediaCapture")
    private var mockTimer: Timer?
    private var audioTimer: Timer?
    private var running: Bool = false
    private var mediaHandler: ((StreamableMediaData) -> Void)?
    private var errorHandler: ((String) -> Void)?
    
    // モック設定を保持
    private var currentImageFormat: ImageFormat = .jpeg
    private var currentImageQuality: ImageQuality = .standard
    private var currentFrameRate: Double = 15.0
    
    /// 無効なターゲットとして扱うID範囲を設定
    private let invalidWindowIDThreshold: CGWindowID = 10000
    private let invalidDisplayIDThreshold: CGDirectDisplayID = 10000
    
    public override init() {
        super.init()
        logger.debug("MockMediaCapture initialized")
    }
    
    // MARK: - オーバーライドメソッド
    
    /// モック版のstartCapture - MediaCaptureと同じシグネチャ
    public override func startCapture(
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
        self.currentImageFormat = imageFormat
        self.currentImageQuality = imageQuality
        self.currentFrameRate = framesPerSecond
        
        // 無効なターゲットをシミュレート
        if target.windowID > invalidWindowIDThreshold || target.displayID > invalidDisplayIDThreshold {
            let errorMsg = "モックエラー: 無効なターゲットID - windowID: \(target.windowID), displayID: \(target.displayID)"
            logger.debug("Throwing error for invalid mock target: \(errorMsg)")
            
            // errorHandlerがあれば呼び出す
            errorHandler?(errorMsg)
            
            // 例外をスロー
            throw NSError(
                domain: "MockMediaCapture", 
                code: 100, 
                userInfo: [NSLocalizedDescriptionKey: errorMsg]
            )
        }
        
        // モックキャプチャの開始
        startMockCapture(
            framesPerSecond: framesPerSecond,
            imageFormat: imageFormat,
            imageQuality: imageQuality
        )
        
        running = true
        return true
    }
    
    /// モック版のstopCapture
    public override func stopCapture() async {
        if running {
            stopMockTimers()
            running = false
            mediaHandler = nil
        }
    }
    
    /// モック版のsynchronous stop
    public override func stopCaptureSync() {
        if running {
            stopMockTimers()
            running = false
            mediaHandler = nil
            errorHandler = nil
        }
    }
    
    /// キャプチャ状態の確認
    public override func isCapturing() -> Bool {
        return running
    }
    
    /// モックターゲット取得用の静的メソッド
    public override class func availableCaptureTargets(ofType type: CaptureTargetType = .all) async throws -> [MediaCaptureTarget] {
        return mockCaptureTargets(type)
    }
    
    // MARK: - モック専用メソッド
    
    /// タイマーの停止
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
    
    /// モックキャプチャ開始
    private func startMockCapture(
        framesPerSecond: Double,
        imageFormat: ImageFormat,
        imageQuality: ImageQuality
    ) {
        logger.debug("Starting mock capture with format: \(imageFormat.rawValue)")
        
        // 既存タイマーのクリア
        stopMockTimers()
        
        // フレームレートの調整
        let includeVideo = framesPerSecond > 0
        let interval = includeVideo ? max(0.1, 1.0 / framesPerSecond) : 0
        
        // オーディオ配信用タイマー設定
        audioTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.generateMockMedia(
                timestamp: Date().timeIntervalSince1970,
                includeVideo: false
            )
        }
        scheduleTimer(audioTimer)
        
        // ビデオ配信用タイマー設定
        if includeVideo {
            // 最初のフレームをすぐに送信
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.generateMockMedia(
                    timestamp: Date().timeIntervalSince1970,
                    includeVideo: true
                )
            }
            
            // 定期的なビデオフレーム配信を設定
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
    
    /// モックメディアデータの生成
    private func generateMockMedia(timestamp: Double, includeVideo: Bool) {
        // ビデオバッファ
        var videoBuffer: Data? = nil
        var videoInfo: StreamableMediaData.Metadata.VideoInfo? = nil
        
        if includeVideo {
            // シンプルなビデオデータ
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
        
        // シンプルな音声データ
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
        
        // メディアデータ構築
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
            audioBuffer: audioBuffer
        )
        
        // メインスレッドでコールバック
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let handler = self.mediaHandler else { return }
            handler(mediaData)
        }
    }
    
    // タイマー設定ヘルパー
    private func scheduleTimer(_ timer: Timer?) {
        guard let timer = timer else { return }
        RunLoop.main.add(timer, forMode: .common)
    }
    
    // モックターゲット生成
    public static func mockCaptureTargets(_ type: CaptureTargetType) -> [MediaCaptureTarget] {
        var targets = [MediaCaptureTarget]()
        
        // メインディスプレイを模したモック
        let mockDisplay = MediaCaptureTarget(
            displayID: 1,
            title: "Mock Display 1",
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        
        // ウィンドウを模したモック
        let mockWindow1 = MediaCaptureTarget(
            windowID: 1,
            title: "Mock Window 1",
            applicationName: "Mock App 1",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        
        // 複数のモックウィンドウ
        let mockWindow2 = MediaCaptureTarget(
            windowID: 2,
            title: "Mock Window 2",
            applicationName: "Mock App 2",
            frame: CGRect(x: 0, y: 0, width: 1024, height: 768)
        )
        
        // 指定種類に応じてフィルタリング
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
