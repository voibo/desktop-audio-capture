import Foundation
import AVFoundation
import CoreGraphics
import ScreenCaptureKit
@testable import MediaCaptureTest

/// MediaCaptureのモッククラス - テスト用
class MockMediaCapture: MediaCapture {
    // モック用の状態管理
    private var mockRunning = false
    private var mockTimer: Timer?
    private var mediaHandler: ((StreamableMediaData) -> Void)?
    private var errorHandler: ((String) -> Void)?
    
    // キャプチャ状態の確認（オーバーライド）
    public override func isCapturing() -> Bool {
        return mockRunning
    }
    
    // キャプチャ開始（オーバーライド）
    public override func startCapture(
        target: MediaCaptureTarget,
        mediaHandler: @escaping (StreamableMediaData) -> Void,
        errorHandler: ((String) -> Void)? = nil,
        framesPerSecond: Double = 30.0,
        quality: CaptureQuality = .high
    ) async throws -> Bool {
        // エラー条件をテスト
        if target.windowID == 99999 {
            errorHandler?("無効なウィンドウID")
            throw NSError(domain: "MockMediaCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "指定されたウィンドウが見つかりません"])
        }
        
        if mockRunning {
            return false
        }
        
        // ハンドラを保存
        self.mediaHandler = mediaHandler
        self.errorHandler = errorHandler
        mockRunning = true
        
        // 最初のフレームをすぐ送信
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.mockRunning {
                self.mediaHandler?(self.createMockMediaData())
            }
        }
        
        // 指定されたフレームレートでフレームを送信するタイマーを設定
        let interval = max(0.1, 1.0 / max(1.0, framesPerSecond))
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.mockTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                guard let self = self, self.mockRunning else { return }
                self.mediaHandler?(self.createMockMediaData())
            }
        }
        
        return true
    }
    
    // キャプチャ停止（オーバーライド）
    public override func stopCapture() async {
        mockTimer?.invalidate()
        mockTimer = nil
        mockRunning = false
        mediaHandler = nil
        errorHandler = nil
    }
    
    // 同期的キャプチャ停止（オーバーライド）
    public override func stopCaptureSync() {
        mockTimer?.invalidate()
        mockTimer = nil
        mockRunning = false
        mediaHandler = nil
        errorHandler = nil
    }
    
    // モックメディアデータを生成
    private func createMockMediaData() -> StreamableMediaData {
        let timestamp = Date().timeIntervalSince1970
        
        // ビデオバッファを生成
        let videoWidth = 640
        let videoHeight = 480
        let bytesPerRow = videoWidth * 4
        let pixelFormat: UInt32 = 1111638594 // kCVPixelFormatType_32BGRA
        
        // グラデーションパターンのダミー画像
        var imageBytes = [UInt8](repeating: 0, count: videoHeight * bytesPerRow)
        for y in 0..<videoHeight {
            for x in 0..<videoWidth {
                let offset = y * bytesPerRow + x * 4
                imageBytes[offset] = UInt8((x + y) % 255)     // B
                imageBytes[offset + 1] = UInt8(y % 255)       // G
                imageBytes[offset + 2] = UInt8(x % 255)       // R
                imageBytes[offset + 3] = 255                  // A
            }
        }
        let videoBuffer = Data(imageBytes)
        
        // オーディオバッファを生成（正弦波）
        let sampleRate = 44100.0
        let channels = 2
        let seconds = 0.1
        let frameCount = Int(sampleRate * seconds)
        let bytesPerSample = 4
        
        var audioBytes = [UInt8](repeating: 0, count: frameCount * channels * bytesPerSample)
        for i in 0..<frameCount {
            // 440Hzの正弦波を生成
            let t = Double(i) / sampleRate
            let value = Float(sin(2.0 * Double.pi * 440.0 * t))
            
            // Float32としてバイト配列に格納
            var floatValue = value
            let floatData = withUnsafeBytes(of: &floatValue) { Array($0) }
            
            // 左右チャンネルに同じ値を設定
            for ch in 0..<channels {
                let offset = (i * channels + ch) * bytesPerSample
                audioBytes[offset..<offset+bytesPerSample] = floatData[0..<bytesPerSample]
            }
        }
        let audioBuffer = Data(audioBytes)
        
        // メタデータを作成
        let videoInfo = StreamableMediaData.Metadata.VideoInfo(
            width: videoWidth,
            height: videoHeight,
            bytesPerRow: bytesPerRow,
            pixelFormat: pixelFormat
        )
        
        let audioInfo = StreamableMediaData.Metadata.AudioInfo(
            sampleRate: sampleRate,
            channelCount: channels,
            bytesPerFrame: UInt32(bytesPerSample * channels),
            frameCount: UInt32(frameCount)
        )
        
        let metadata = StreamableMediaData.Metadata(
            timestamp: timestamp,
            hasVideo: true,
            hasAudio: true,
            videoInfo: videoInfo,
            audioInfo: audioInfo
        )
        
        // StreamableMediaDataを返す
        return StreamableMediaData(
            metadata: metadata,
            videoBuffer: videoBuffer,
            audioBuffer: audioBuffer
        )
    }
}
