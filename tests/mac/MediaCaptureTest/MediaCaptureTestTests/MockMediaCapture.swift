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
    private var mockCaptureTask: Task<Void, Never>?
    
    // Check capture state (override)
    public override func isCapturing() -> Bool {
        return mockRunning
    }
    
    // startCapture メソッドを修正
    public override func startCapture(
        target: MediaCaptureTarget,
        mediaHandler: @escaping (StreamableMediaData) -> Void,
        errorHandler: ((String) -> Void)? = nil,
        framesPerSecond: Double = 30.0,
        quality: CaptureQuality = .high
    ) async throws -> Bool {
        // テスト条件のチェック
        if target.windowID == 99999 {
            if let errorHandler = errorHandler {
                errorHandler("Mock error: Invalid window ID")
            }
            throw NSError(domain: "MockCapture", code: 100, userInfo: [NSLocalizedDescriptionKey: "Invalid window ID"])
        }
        
        if mockRunning {
            return false
        }
        
        // ハンドラを保存
        self.mediaHandler = mediaHandler
        self.errorHandler = errorHandler
        mockRunning = true
        
        // 既存のタスクをキャンセル
        mockCaptureTask?.cancel()
        mockCaptureTask = nil
        
        // フレームレートとクオリティに基づいて適切なモードを選択
        if framesPerSecond == 0 {
            // オーディオのみのモード (testAudioOnlyCapture用)
            print("Starting audio-only mock capture")
            startAudioOnlyMockCapture()
        } else {
            // 通常のビデオ+オーディオモード
            print("Starting normal mock capture at \(framesPerSecond) FPS")
            startPrecisionMockCapture(framesPerSecond: framesPerSecond)
        }
        
        return true
    }
    
    // キャプチャ停止の改善
    public override func stopCapture() async {
        mockCaptureTask?.cancel()
        mockCaptureTask = nil
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
    
    // モックメディアデータ生成を修正
    private func createMockMediaData(frameNumber: Int) async -> StreamableMediaData {
        // ビデオバッファの作成
        let width = 640
        let height = 480
        let bytesPerRow = width * 4
        var videoData = Data(count: bytesPerRow * height)
        
        // フレーム番号で変化するパターンでデータを埋める
        let pattern = UInt8((frameNumber % 255))
        videoData.withUnsafeMutableBytes { buffer in
            for i in 0..<buffer.count {
                buffer[i] = pattern + UInt8(i % 64)
            }
        }
        
        // オーディオバッファの作成
        let audioChannels = 2
        let audioFrames = 1024
        let audioBytes = audioChannels * audioFrames * 4 // Float32のサイズは4バイト
        var audioData = Data(count: audioBytes)
        
        // 実際にサイン波のデータを生成（無音ではない）
        audioData.withUnsafeMutableBytes { buffer in
            let floatBuffer = buffer.bindMemory(to: Float32.self)
            let frequency: Float32 = 440.0 // A4ノート
            
            for i in 0..<audioFrames {
                let time = Float32(i) / 44100.0
                let value = sin(2.0 * Float32.pi * frequency * time) * 0.5
                
                // 左右のチャンネルに値をセット
                floatBuffer[i * 2] = value
                floatBuffer[i * 2 + 1] = value
            }
        }
        
        // メタデータの作成
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
                frameCount: UInt32(audioFrames)
            )
        )
        
        return StreamableMediaData(
            metadata: metadata,
            videoBuffer: videoData,
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
            
            // フレームカウンター追加
            var frameCount = 0
            
            while self.mockRunning {
                // フレームカウンターをインクリメント
                frameCount += 1
                
                // Generate mock media data (frameNumberパラメータを追加、awaitキーワード追加)
                let mediaData = await self.createMockMediaData(frameNumber: frameCount)
                
                // Send to handler on main thread
                Task { @MainActor in
                    self.mediaHandler?(mediaData)
                }
                
                // Delay based on frame rate
                try? await Task.sleep(for: .seconds(delayInSeconds))
            }
        }
    }

    // 高精度モックキャプチャ実装を修正
    private func startPrecisionMockCapture(framesPerSecond: Double) {
        if framesPerSecond <= 0 {
            return // 無効なFPS
        }
        
        // 強い参照サイクルを避けるための弱参照を持つタスク
        mockCaptureTask = Task { [weak self] in
            // self参照のチェック
            guard let self = self else { return }
            
            let frameInterval = 1.0 / framesPerSecond
            let frameIntervalNanos = UInt64(frameInterval * 1_000_000_000)
            var nextFrameTime = DispatchTime.now().uptimeNanoseconds
            var frameCount = 0
            
            // キャプチャ中のループ
            while !Task.isCancelled && self.mockRunning {
                frameCount += 1
                
                // 次のフレームタイミングまでスリープ
                let currentTime = DispatchTime.now().uptimeNanoseconds
                if currentTime < nextFrameTime {
                    let sleepTime = nextFrameTime - currentTime
                    try? await Task.sleep(nanoseconds: sleepTime)
                }
                
                // モックメディアデータを作成 - frameNumberパラメータを追加
                let mediaData = await createMockMediaData(frameNumber: frameCount)
                
                // メインスレッドでハンドラを呼び出し
                let handler = self.mediaHandler
                if let handler = handler {
                    await MainActor.run {
                        handler(mediaData)
                    }
                }
                
                // 次のフレーム時間を設定
                nextFrameTime += frameIntervalNanos
            }
        }
    }

    // オーディオのみのモックキャプチャ機能を追加
    private func startAudioOnlyMockCapture() {
        mockCaptureTask = Task { [weak self] in
            guard let self = self else { return }
            
            var frameCount = 0
            // オーディオサンプルは約100msごとに送信
            let audioInterval = 0.1
            
            while !Task.isCancelled && self.mockRunning {
                frameCount += 1
                
                // オーディオのみのデータを作成
                let audioData = await createAudioOnlyData(frameNumber: frameCount)
                
                // メインスレッドでハンドラを呼び出し
                if let handler = self.mediaHandler {
                    await MainActor.run {
                        handler(audioData)
                    }
                }
                
                // 次のオーディオフレームまで待機
                try? await Task.sleep(for: .seconds(audioInterval))
            }
        }
    }

    // オーディオのみのデータ生成関数
    private func createAudioOnlyData(frameNumber: Int) async -> StreamableMediaData {
        // オーディオバッファの作成
        let audioChannels = 2
        let audioFrames = 1024
        let audioBytes = audioChannels * audioFrames * 4 // Float32のサイズは4バイト
        var audioData = Data(count: audioBytes)
        
        // サイン波を生成（周波数はフレーム番号によって変化）
        audioData.withUnsafeMutableBytes { buffer in
            let floatBuffer = buffer.bindMemory(to: Float32.self)
            let frequency: Float32 = 440.0 + Float32(frameNumber % 10) * 20.0 // A4音+変調
            
            for i in 0..<audioFrames {
                let time = Float32(i) / 44100.0
                let value = sin(2.0 * Float32.pi * frequency * time) * 0.5
                
                // ステレオチャンネル
                floatBuffer[i * 2] = value
                floatBuffer[i * 2 + 1] = value * 0.8
            }
        }
        
        // オーディオのみのメタデータ
        let metadata = StreamableMediaData.Metadata(
            timestamp: Date().timeIntervalSince1970,
            hasVideo: false, // ビデオなし
            hasAudio: true,  // オーディオあり
            videoInfo: nil,  // ビデオ情報なし
            audioInfo: StreamableMediaData.Metadata.AudioInfo(
                sampleRate: 44100,
                channelCount: 2,
                bytesPerFrame: 4,
                frameCount: UInt32(audioFrames)
            )
        )
        
        return StreamableMediaData(
            metadata: metadata,
            videoBuffer: nil, // ビデオなし
            audioBuffer: audioData
        )
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
