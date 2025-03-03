import SwiftUI
import Combine
import AVFoundation
import ScreenCaptureKit

@MainActor
class MediaCaptureViewModel: ObservableObject {
    // Capture settings
    @Published var selectedTargetIndex = 0
    @Published var selectedQuality = 0
    @Published var frameRate: Double = 30.0
    @Published var audioOnly = false
    @Published var searchText = ""
    @Published var frameRateMode = 0  // 0: Standard, 1: Low speed
    @Published var lowFrameRate: Double = 0.2  // Default is every 5 seconds (0.2fps)
    
    // Capture target
    @Published var availableTargets: [MediaCaptureTarget] = []
    @Published var isLoading = false
    
    // Capture status
    @Published var errorMessage: String? = nil
    @Published var statusMessage: String = "Ready"
    
    // Statistics
    @Published var frameCount = 0
    @Published var currentFPS: Double = 0
    @Published var imageSize = "-"
    @Published var audioSampleRate: Double = 0
    @Published var captureLatency: Double = 0
    @Published var audioLevel: Float = 0
    
    // Preview
    @Published var previewImage: NSImage? = nil
    
    // For frame rate calculation
    private var lastFrameTime = Date()
    private var frameCountInLastSecond = 0
    
    // Media capture
    private var mediaCapture = MediaCapture()
    private var fpsUpdateTimer: Timer? = nil
    
    // History data for audio waveform display (max 100 samples)
    @Published var audioLevelHistory: [Float] = Array(repeating: 0, count: 100)
    
    // Audio capture related
    @Published var audioFileURL: URL? = nil
    @Published var audioFormat: AVAudioFormat? = nil
    @Published var audioFormatDescription: String = "-"
    @Published var audioChannelCount: Int = 0
    
    private var lastAudioFormat: AVAudioFormat? = nil
    private var audioSampleRateValue: Double = 0
    private var audioChannelCountValue: Int = 0
    
    @Published var memoryUsageMessage: String = "-"
    
    // Backing property for access separated from MainActor
    // Explicitly manage concurrency safety manually
    nonisolated(unsafe) private var _isCapturingStorage: Bool = false

    // MainActor isolated property
    var isCapturing: Bool {
        get { _isCapturingStorage }
        set { _isCapturingStorage = newValue }
    }

    // Non-isolated read-only property
    nonisolated var isCapturingNonisolated: Bool {
        _isCapturingStorage
    }

    // Capture target type property
    @Published var captureTargetType: MediaCapture.CaptureTargetType = .all
    @Published var availableScreens: [MediaCaptureTarget] = []
    @Published var availableWindows: [MediaCaptureTarget] = []

    // Filtered targets property (combines search and target type filtering)
    var filteredTargets: [MediaCaptureTarget] {
        // First filter by selected target type
        let targetsToFilter: [MediaCaptureTarget]
        switch captureTargetType {
            case .screen:
                targetsToFilter = availableScreens
            case .window:
                targetsToFilter = availableWindows
            case .all:
                targetsToFilter = availableTargets
        }
        
        // Then apply search text filtering
        if searchText.isEmpty {
            return targetsToFilter
        } else {
            return targetsToFilter.filter { target in
                let title = target.title ?? ""
                let appName = target.applicationName ?? ""
                return title.localizedCaseInsensitiveContains(searchText) || 
                       appName.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    // init method error checking also uses nonisolated
    init() {
        // To safely get the value of a property from a nonisolated context,
        // make the Timer's closure Sendable-compliant
        fpsUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // Do nothing if the capture reference is nil
            guard let self = self else { return }
            
            // Determine before checking the isCapturing state
            let isCurrentlyCapturing = self.isCapturingNonisolated
            if (!isCurrentlyCapturing) {
                return
            }
            
            // Access properties in the MainActor context
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                let now = Date()
                let elapsedTime = now.timeIntervalSince(self.lastFrameTime)
                self.currentFPS = Double(self.frameCountInLastSecond) / elapsedTime
                self.frameCountInLastSecond = 0
                self.lastFrameTime = now
            }
        }
    }
    
    deinit {
        print("MediaCaptureViewModel has been deinit")
        
        // Clear timer
        fpsUpdateTimer?.invalidate()
        fpsUpdateTimer = nil
        
        // Stop capturing synchronously
        // Use nonisolated property
        let capture = mediaCapture
        let wasCapturing = isCapturingNonisolated // Modified here
        
        // Only code that can be executed outside the MainActor context
        if wasCapturing {
            capture.stopCaptureSync()
            
            // UI state cannot be updated (because it is in deinit)
            print("deinit: Capture stopped")
        }
    }
    
    // Load available capture targets
    func loadAvailableTargets() async {
        isLoading = true
        errorMessage = nil
        
        do {
            // Get all capture targets
            let allTargets = try await MediaCapture.availableCaptureTargets(ofType: .all)
            // Get screens and windows separately
            let screens = try await MediaCapture.availableCaptureTargets(ofType: .screen)
            let windows = try await MediaCapture.availableCaptureTargets(ofType: .window)
            
            self.availableTargets = allTargets
            self.availableScreens = screens
            self.availableWindows = windows
            
            self.isLoading = false
            
            if allTargets.isEmpty {
                self.errorMessage = "No available capture targets found."
            } else {
                print("Available capture targets: \(screens.count) screens, \(windows.count) windows, \(allTargets.count) total")
            }
        } catch {
            self.isLoading = false
            self.errorMessage = "Error loading capture targets: \(error.localizedDescription)"
        }
    }
    
    // Start capturing
    func startCapture() async {
        guard !isCapturing, !availableTargets.isEmpty, selectedTargetIndex < filteredTargets.count else { 
            // @MainActor does not require DispatchQueue.main.async
            errorMessage = "The selected capture target is invalid."
            return
        }
        
        // Initialize UI state
        errorMessage = nil
        statusMessage = "Preparing to capture..."
        frameCount = 0
        currentFPS = 0
        frameCountInLastSecond = 0
        lastFrameTime = Date()
        
        // Selected target
        let selectedTarget = filteredTargets[selectedTargetIndex]
        
        // Quality settings
        let quality: MediaCapture.CaptureQuality
        switch (selectedQuality) {
            case 0: quality = .high
            case 1: quality = .medium
            default: quality = .low
        }
        
        // Frame rate settings
        let fps = audioOnly ? 0.0 : (frameRateMode == 0 ? frameRate : lowFrameRate)
        
        // キャプチャフォルダの初期化（rawDataSavingEnabledがtrueの場合）
        if rawDataSavingEnabled {
            _ = rawDataManager.initializeSession(
                frameRate: frameRateMode == 0 ? frameRate : lowFrameRate,
                quality: selectedQuality
            )
        }

        do {
            let success = try await mediaCapture.startCapture(
                target: selectedTarget,
                mediaHandler: { [weak self] media in
                    Task { @MainActor [weak self] in
                        self?.processMedia(media)
                    }
                },
                errorHandler: { [weak self] errorMessage in
                    Task { @MainActor [weak self] in
                        self?.errorMessage = errorMessage
                    }
                },
                framesPerSecond: fps,
                quality: quality
            )
            
            // @MainActor does not require DispatchQueue.main.async
            if success {
                isCapturing = true
                statusMessage = "Capturing..."
                print("Capture started: isCapturing = \(isCapturing)")
            } else {
                errorMessage = "Failed to start capture"
                statusMessage = "Ready"
            }
        } catch {
            // @MainActor does not require DispatchQueue.main.async
            errorMessage = "Capture start error: \(error.localizedDescription)"
            statusMessage = "Ready"
        }
    }
    
    // stopCapture メソッドの修正
    func stopCapture() async {
        guard isCapturing else { return }
        
        // 更新状態
        statusMessage = "Stopping capture..."
        
        // キャプチャを停止
        mediaCapture.stopCaptureSync()
        
        // 生データが有効な場合、メタデータJSONを保存
        if rawDataSavingEnabled {
            // 音声データをファイルに保存
            _ = await rawDataManager.finalizeSession(
                audioSampleRate: audioSampleRate,
                channelCount: audioChannelCount
            )
            
            // 最終的な保存フォルダの情報を取得
            if let folder = rawDataManager.captureFolder {
                print("DEBUG: キャプチャデータが保存されました: \(folder.path)")
                
                // キャプチャ完了の通知を送信
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .captureCompleted, object: self)
                }
            }
        }

        // UI更新 - @MainActorではDispatchQueue.main.asyncは不要
        isCapturing = false
        previewImage = nil
        frameCountInLastSecond = 0
        currentFPS = 0
        statusMessage = "Capture stopped"
        print("Capture stopped: isCapturing = \(isCapturing)")
    }
    
    // Process media data
    private func processMedia(_ media: StreamableMediaData) {
        // @MainActor, code in this method is already executed on the main thread
        
        // Process audio information
        if let audioInfo = media.metadata.audioInfo {
            // Get format information
            audioSampleRate = audioInfo.sampleRate
            audioChannelCount = audioInfo.channelCount
        }
        
        // Calculate latency
        let now = Date().timeIntervalSince1970
        let latency = (now - media.metadata.timestamp) * 1000 // milliseconds
        captureLatency = latency
        
        // Video frame processing
        if let videoBuffer = media.videoBuffer, let videoInfo = media.metadata.videoInfo {
            // Update image size
            imageSize = "\(videoInfo.width) × \(videoInfo.height)"
            
            // Update frame count
            frameCount += 1
            frameCountInLastSecond += 1
            
            // Update preview image (thin out to reduce frame rate)
            if frameCount % 5 == 0 {  // Update only once every 5 frames
                if let image = createImageFromBuffer(
                    videoBuffer,
                    width: videoInfo.width,
                    height: videoInfo.height,
                    bytesPerRow: videoInfo.bytesPerRow,
                    pixelFormat: videoInfo.pixelFormat
                ) {
                    previewImage = image
                }
            }
        }
        
        // Audio level processing
        if let audioBuffer = media.audioBuffer, audioBuffer.count > 0 {
            // Simple implementation
            let audioSamples = [UInt8](audioBuffer)
            var sum: Float = 0
            
            // Limit the number of samples
            let step = max(1, audioSamples.count / 50)
            for i in stride(from: 0, to: audioSamples.count, by: step) {
                let sample = Float(audioSamples[i]) / 255.0
                sum += sample * sample
            }
            
            let rms = sqrt(sum / Float(audioSamples.count / step))
            audioLevel = min(rms * 5, 1.0)
            
            // Update audio level history
            if frameCount % 3 == 0 {
                audioLevelHistory.removeFirst()
                audioLevelHistory.append(audioLevel)
            }
        }

        // 生データ保存（有効かつフォルダが初期化されている場合）
        if rawDataSavingEnabled {
            // 音声データをバッファに追加
            if let audioBuffer = media.audioBuffer, audioBuffer.count > 0 {
                rawDataManager.appendAudioData(audioBuffer)
            }
            
            // ビデオフレームを保存
            if let videoData = media.videoBuffer, let videoInfo = media.metadata.videoInfo {
                // JPEGフォーマット情報と品質設定を渡す
                Task {
                    await self.rawDataManager.saveFrameData(
                        videoData,
                        timestamp: media.metadata.timestamp,
                        width: videoInfo.width,
                        height: videoInfo.height,
                        bytesPerRow: videoInfo.bytesPerRow,
                        pixelFormat: videoInfo.pixelFormat,
                        format: videoInfo.format,     // "jpeg" または "raw"
                        quality: videoInfo.quality    // JPEG品質（オプショナル）
                    )
                }
            }
            
            // ステータスの更新（一定間隔で）
            if frameCount % 30 == 0 {
                updateRawDataStatus()
            }
        }
    }
    
    // Convert video buffer to NSImage
    private func createImageFromBuffer(_ data: Data, width: Int, height: Int, bytesPerRow: Int, pixelFormat: UInt32) -> NSImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }
        
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    // Check memory usage during recording
    private func checkMemoryUsage() {
        guard rawDataSavingEnabled else { return }
        
        let audioSize = rawDataManager.audioBufferSize
        let sizeMB = audioSize / (1024 * 1024)
        
        // @MainActor does not require DispatchQueue.main.async
        memoryUsageMessage = "Memory Usage: \(sizeMB)MB (audio buffer)"
        
        // 警告
        if sizeMB > 500 {
            errorMessage = "Warning: Memory usage is high (\(sizeMB)MB). Stop capturing and save."
        }
    }

    @Published var selectedTab = 0
    @Published var audioWaveformData: [Float] = []
    @Published var captureTime: Double = 0.0

    // メディアデータ汎用処理メソッド
    func handleMediaData(_ media: StreamableMediaData) {
        // この方がパフォーマンスに優れているはず
        let now = Date().timeIntervalSince1970
        let latency = (now - media.metadata.timestamp) * 1000 // ミリ秒
        captureLatency = latency
        
        // ビデオデータの処理
        if let videoBuffer = media.videoBuffer, let videoInfo = media.metadata.videoInfo {
            // イメージサイズの更新
            imageSize = "\(videoInfo.width) × \(videoInfo.height)"
            
            // フレームカウントの更新
            frameCount += 1
            frameCountInLastSecond += 1
            
            // プレビュー画像の更新（負荷軽減のため間引き）
            if frameCount % 2 == 0 {  // 2フレームに1回に変更
                if let image = createImageFromBuffer(
                    videoBuffer,
                    width: videoInfo.width,
                    height: videoInfo.height,
                    bytesPerRow: videoInfo.bytesPerRow,
                    pixelFormat: videoInfo.pixelFormat
                ) {
                    previewImage = image
                }
            }
        }
        
        // オーディオデータの処理
        if let audioBuffer = media.audioBuffer, audioBuffer.count > 0,
           let audioInfo = media.metadata.audioInfo {
            // オーディオレベルの計算（効率化）
            let samplesPerChannel = audioBuffer.count / Int(audioInfo.bytesPerFrame)
            
            // より効率的なオーディオレベル計算
            var sum: Float = 0
            audioBuffer.withUnsafeBytes { ptr in
                if let floatPtr = ptr.baseAddress?.assumingMemoryBound(to: Float32.self) {
                    // サンプル数を制限して処理負荷を軽減
                    let step = max(1, samplesPerChannel * Int(audioInfo.channelCount) / 100)
                    var count = 0
                    
                    for i in stride(from: 0, to: samplesPerChannel * Int(audioInfo.channelCount), by: step) {
                        let sample = abs(floatPtr[i])
                        sum += sample
                        count += 1
                    }
                    
                    sum = count > 0 ? sum / Float(count) : 0
                }
            }
            
            // 標準的な音声レベルに正規化
            audioLevel = min(sum * 2, 1.0)
            
            // オーディオレベル履歴の更新（間引き）
            if frameCount % 3 == 0 {
                audioLevelHistory.removeFirst()
                audioLevelHistory.append(audioLevel)
            }
            
            // キャプチャー時間の更新
            captureTime += Double(samplesPerChannel) / audioInfo.sampleRate
        }
    }
    
    // 生データ管理用のインスタンス
    private let rawDataManager = RawDataManager()
    
    // RawDataManager に委譲するプロパティ
    @Published var rawDataSavingEnabled: Bool = true {
        didSet {
            rawDataManager.isEnabled = rawDataSavingEnabled
        }
    }
    @Published var captureSessionFolder: URL?
    @Published var savedFrameCount: Int = 0
    @Published var savedAudioDataSize: Int = 0
    @Published var isSavingData: Bool = false

    // RawDataManager の状態を同期する処理を追加
    func updateRawDataStatus() {
        savedFrameCount = rawDataManager.savedFrameCount
        savedAudioDataSize = rawDataManager.audioBufferSize / 1024 // KB単位
        isSavingData = rawDataManager.isSaving
        if let folder = rawDataManager.captureFolder {
            captureSessionFolder = folder
        }
    }
}
