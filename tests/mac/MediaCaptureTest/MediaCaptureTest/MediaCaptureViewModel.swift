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
    @Published var isAudioRecording = false
    @Published var audioRecordingTime: TimeInterval = 0
    @Published var audioFileURL: URL? = nil
    @Published var audioFormat: AVAudioFormat? = nil
    @Published var audioFormatDescription: String = "-"
    @Published var audioChannelCount: Int = 0
    
    private var audioBuffers: [Data] = []
    private var audioRecordingStartTime: Date? = nil
    private var audioRecordingTimer: Timer? = nil
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
    
    // Timeline data structures
    @Published var isTimelineCapturingEnabled = false
    @Published var timelineAudioSamples: [Float] = []
    @Published var timelineThumbnails: [TimelineThumbnail] = []
    @Published var timelineCurrentPosition: TimeInterval = 0
    @Published var timelineTotalDuration: TimeInterval = 30.0  // 30 seconds by default
    @Published var timelineZoomLevel: Double = 1.0  // 1.0 = normal zoom

    // Define thumbnail structure
    public struct TimelineThumbnail: Identifiable {
        public let id = UUID()
        public let image: NSImage
        public let timestamp: TimeInterval
    }

    // Timeline capturing
    private var lastThumbnailTime: TimeInterval = 0
    private var thumbnailInterval: TimeInterval {
        // Dynamically calculate thumbnail interval based on frame rate
        if audioOnly {
            return 2.0 // Every 2 seconds for audio-only mode
        } else if frameRateMode == 0 {
            // Standard mode: reflect actual frame rate
            return 1.0 / frameRate
        } else {
            // Low speed mode: reflect actual frame rate
            return 1.0 / lowFrameRate
        }
    }

    // Playback control properties
    @Published var isPlaying: Bool = false
    @Published var currentPlaybackPosition: TimeInterval = 0
    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var playbackStartTime: TimeInterval = 0
    private var playbackOffset: TimeInterval = 0

    // Properties for converting PCM format audio data for AVAudioPlayer
    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?

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
        
        audioRecordingTimer?.invalidate()
        audioRecordingTimer = nil
        
        // Clear audio buffer
        audioBuffers.removeAll()
        
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
        
        // Reset timeline related data
        lastThumbnailTime = 0
        timelineAudioSamples = []
        timelineThumbnails = []
        timelineCurrentPosition = 0

        // Selected target
        let selectedTarget = filteredTargets[selectedTargetIndex]
        
        // Quality settings
        let quality: MediaCapture.CaptureQuality
        switch selectedQuality {
            case 0: quality = .high
            case 1: quality = .medium
            default: quality = .low
        }
        
        // Frame rate settings
        let fps = audioOnly ? 0.0 : (frameRateMode == 0 ? frameRate : lowFrameRate)
        
        do {
            // Start capturing - This is an important change point
            let success = try await mediaCapture.startCapture(
                target: selectedTarget,
                mediaHandler: { [weak self] media in
                    // To call a MainActor method from a @Sendable closure,
                    // use Task { @MainActor in ... }
                    Task { @MainActor [weak self] in
                        self?.processMedia(media)
                    }
                },
                errorHandler: { [weak self] errorMessage in
                    // To update a MainActor property from a @Sendable closure,
                    // use Task { @MainActor in ... }
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
                startAudioRecording()
                
                // Reset timeline related variables
                lastThumbnailTime = 0
                
                // Start timeline capturing automatically when capture starts
                toggleTimelineCapturing(true)
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
    
    // Stop capturing
    func stopCapture() async {
        guard isCapturing else { return }
        
        // Update state
        statusMessage = "Stopping capture..."
        
        // Stop audio recording
        if isAudioRecording {
            stopAudioRecording()
        }
        
        // Stop capture
        mediaCapture.stopCaptureSync()
        
        // UI update - @MainActor does not require DispatchQueue.main.async
        isCapturing = false
        previewImage = nil
        frameCountInLastSecond = 0
        currentFPS = 0
        statusMessage = "Capture stopped"
        print("Capture stopped: isCapturing = \(isCapturing)")
    }
    
    // Start audio recording
    func startAudioRecording() {
        guard isCapturing, !isAudioRecording else { return }
        
        // Initialize buffer
        audioBuffers.removeAll()
        audioFileURL = nil
        audioRecordingTime = 0
        audioRecordingStartTime = Date()
        isAudioRecording = true
        
        // Recording time update timer - Timer closure is treated as a non-isolated context
        audioRecordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            // Access properties in the MainActor context
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Skip if audioRecordingStartTime is nil
                guard let startTime = self.audioRecordingStartTime else { return }
                
                self.audioRecordingTime = Date().timeIntervalSince(startTime)
                
                // Simple buffer size check
                if self.audioRecordingTime.truncatingRemainder(dividingBy: 10) < 0.1 {
                    self.checkMemoryUsage()
                }
            }
        }
    }
    
    // Stop audio recording and save
    func stopAudioRecording() {
        guard isAudioRecording else { return }
        
        // Stop timer
        audioRecordingTimer?.invalidate()
        audioRecordingTimer = nil
        isAudioRecording = false
        
        // Save process
        saveAudioToFile()
    }
    
    // Save audio data to a file
    private func saveAudioToFile() {
        guard !audioBuffers.isEmpty else {
            errorMessage = "No audio data to save"
            return
        }
        
        // Create the file path to save to
        let tempDir = FileManager.default.temporaryDirectory
        
        // Check that the directory exists
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            print("Directory creation error: \(error)")
        }
        
        let fileName = "audio_capture_\(Int(Date().timeIntervalSince1970)).pcm"
        let fileURL = tempDir.appendingPathComponent(fileName)
        
        do {
            // Data size warning
            let totalSize = audioBuffers.reduce(0) { $0 + $1.count }
            print("Saving: \(totalSize / (1024 * 1024))MB of audio data")
            
            // Create an empty file first
            try Data().write(to: fileURL)
            
            // Write buffers efficiently one by one
            let fileHandle = try FileHandle(forWritingTo: fileURL)
            defer { 
                try? fileHandle.close()
            }
            
            // Write buffers one by one
            let totalBuffers = audioBuffers.count
            for (index, buffer) in audioBuffers.enumerated() {
                try fileHandle.write(contentsOf: buffer)
                
                // Progress report (every 10%)
                if index % max(1, totalBuffers / 10) == 0 || index == totalBuffers - 1 {
                    let progress = Double(index + 1) / Double(totalBuffers) * 100
                    print("Saving progress: \(Int(progress))%")
                }
            }
            
            // Clear buffer (release memory)
            audioBuffers.removeAll()
            
            // Success
            audioFileURL = fileURL
            
            // Update format information
            updateAudioFormatDescription()
            errorMessage = "Audio file saved: \(fileURL.lastPathComponent)"
            
            print("FFplay command: \(getFFplayCommand())")
        } catch {
            print("File save error: \(error)")
            errorMessage = "Failed to write audio file: \(error.localizedDescription)"
        }
    }
    
    // Generate command to play with ffplay
    private func generateFFplayCommand(format: AVAudioFormat, fileURL: URL) -> String {
        let sampleRate = Int(format.sampleRate)
        let channels = Int(format.channelCount)
        let isFloat = format.commonFormat == .pcmFormatFloat32        
        let chLayout = channels == 2 ? "stereo" : "mono"
        return "ffplay -f \(isFloat ? "f32le" : "s16le") -ar \(sampleRate) -ch_layout \(chLayout) \"\(fileURL.path)\""
    }
    
    // Update audio format information string
    private func updateAudioFormatDescription() {
        // Build format information
        var formatInfo = [String]()
        formatInfo.append("Sample Rate: \(Int(audioSampleRate)) Hz")
        formatInfo.append("Channel Count: \(audioChannelCount)")
        formatInfo.append("Bit Depth: 32-bit Floating Point")
        formatInfo.append("Format: PCM Float32 Little Endian")
        formatInfo.append("ffplay command: ffplay -f f32le -ar \(Int(audioSampleRate)) -ac \(audioChannelCount) \"filename\"")
        
        audioFormatDescription = formatInfo.joined(separator: "\n")
    }
    
    // Generate ffplay command
    func getFFplayCommand() -> String {
        guard let url = audioFileURL else { return "" }
        return "ffplay -f f32le -ar \(Int(audioSampleRate)) -ac \(audioChannelCount) \"\(url.path)\""
    }

    // Convert audio data to mono and save to file
    func saveAudioToMonoFile() {
        guard !audioBuffers.isEmpty else {
            errorMessage = "No audio data to save"
            return
        }
        
        // Execute only if the buffer has not already been saved
        guard let originalURL = audioFileURL else {
            errorMessage = "Please stop recording and save first"
            return
        }
        
        // Create the file path to save to
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "audio_mono_\(Int(Date().timeIntervalSince1970)).pcm"
        let fileURL = tempDir.appendingPathComponent(fileName)
        
        do {
            // Stereo -> Mono conversion progress display
            statusMessage = "Converting to mono..."
            
            // Since it is 32-bit floating point, process 4 bytes as 1 sample
            let bytesPerSample = 4
            
            // Read data from the already saved file
            let fileData = try Data(contentsOf: originalURL)
            let totalSamples = fileData.count / bytesPerSample
            
            // Create file handle
            try Data().write(to: fileURL)
            let fileHandle = try FileHandle(forWritingTo: fileURL)
            defer { try? fileHandle.close() }
            
            // Buffer size (chunk size)
            let bufferSize = 1024 * 1024 // 1MB
            let samplesPerBuffer = bufferSize / bytesPerSample
            let totalBuffers = (totalSamples + samplesPerBuffer - 1) / samplesPerBuffer
            
            print("Start mono conversion: Total samples=\(totalSamples), Number of buffers=\(totalBuffers)")
            
            // If stereo, if the number of channels is 2
            if audioChannelCount == 2 {
                // Count the number of converted samples
                var processedSamples = 0
                
                for bufferIndex in 0..<totalBuffers {
                    let startSample = bufferIndex * samplesPerBuffer
                    let endSample = min(startSample + samplesPerBuffer, totalSamples)
                    let currentSamples = endSample - startSample
                    
                    var monoBuffer = Data(capacity: currentSamples * bytesPerSample / 2)
                    
                    for i in 0..<(currentSamples / 2) {
                        let stereoIndex = startSample + i * 2
                        
                        // Left and right channel indices
                        let leftIdx = stereoIndex * bytesPerSample
                        let rightIdx = (stereoIndex + 1) * bytesPerSample
                        
                        if leftIdx + bytesPerSample <= fileData.count && rightIdx + bytesPerSample <= fileData.count {
                            // Get left and right channel data
                            let leftBytes = fileData[leftIdx..<leftIdx+bytesPerSample]
                            let rightBytes = fileData[rightIdx..<rightIdx+bytesPerSample]
                            
                            // Convert to Float32
                            var leftValue: Float = 0
                            var rightValue: Float = 0
                            
                            (leftBytes as NSData).getBytes(&leftValue, length: bytesPerSample)
                            (rightBytes as NSData).getBytes(&rightValue, length: bytesPerSample)
                            
                            // Take the average of the left and right
                            let monoValue = (leftValue + rightValue) / 2.0
                            
                            // Convert Float32 to byte string
                            var monoBytes = monoValue
                            monoBuffer.append(Data(bytes: &monoBytes, count: bytesPerSample))
                            
                            processedSamples += 2
                        }
                    }
                    
                    // Write buffer to file
                    fileHandle.write(monoBuffer)
                    
                    // Progress report
                    let progress = Double(processedSamples) / Double(totalSamples) * 100
                    if bufferIndex % 10 == 0 || bufferIndex == totalBuffers - 1 {
                        print("Mono conversion progress: \(Int(progress))%")
                    }
                }
            } else {
                // If it is already mono, copy it as is
                fileHandle.write(fileData)
            }
            
            // UI update
            statusMessage = "Mono conversion complete"
            errorMessage = "Mono audio file saved: \(fileURL.lastPathComponent)"
            
            // Generate ffplay command (for mono)
            let ffplayCommand = "ffplay -f f32le -ar \(Int(audioSampleRate)) -ac 1 \"\(fileURL.path)\""
            print("Mono file saved: \(fileURL.path)")
            print("FFplay command (mono): \(ffplayCommand)")
            
        } catch {
            statusMessage = "Ready"
            errorMessage = "Mono conversion failed: \(error.localizedDescription)"
        }
    }

    // Get ffplay command for mono file
    func getMonoFFplayCommand() -> String {
        guard let url = audioFileURL else { return "" }
        return "ffplay -f f32le -ar \(Int(audioSampleRate)) -ac 1 \"\(url.path)\""
    }

    // Process media data
    private func processMedia(_ media: StreamableMediaData) {
        // @MainActor, code in this method is already executed on the main thread
        
        // Process audio information
        if let audioInfo = media.metadata.audioInfo {
            // Get format information
            audioSampleRate = audioInfo.sampleRate
            audioChannelCount = audioInfo.channelCount
            
            // Add to buffer if recording
            if isAudioRecording, let audioBuffer = media.audioBuffer {
                audioBuffers.append(audioBuffer)
            }
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

        // Timeline capturing
        if isTimelineCapturingEnabled {
            // Add audio sample to timeline with improved sampling
            if let audioBuffer = media.audioBuffer, audioBuffer.count > 0 {
                // Extract actual PCM data for better waveform representation
                let audioSamples = extractPCMSamples(from: audioBuffer, channelCount: audioChannelCount)
                
                // Add audio samples without limit (no upper bound)
                timelineAudioSamples.append(contentsOf: audioSamples)
                
                // Add extra debug info every 5000 samples
                if audioSamples.count > 0 && timelineAudioSamples.count % 5000 == 0 {
                    print("Audio samples count: \(timelineAudioSamples.count), current time: \(audioRecordingTime)s")
                }
            }
            
            // Capture thumbnails at regular intervals
            let currentTime = audioRecordingTime
            let currentInterval = thumbnailInterval // Get current interval setting

            // Always capture the first frame, then capture based on interval
            let shouldCapture = timelineThumbnails.isEmpty || 
                                (currentTime - lastThumbnailTime >= currentInterval)

            if shouldCapture, let image = previewImage {
                lastThumbnailTime = currentTime
                
                let thumbnail = TimelineThumbnail(
                    image: image,
                    timestamp: currentTime
                )
                timelineThumbnails.append(thumbnail)
                
                // Debug information
                print("Timeline: Captured thumbnail at \(String(format: "%.2f", currentTime))s, interval: \(String(format: "%.2f", currentInterval))s")
                print("Timeline: Current mode: \(frameRateMode == 0 ? "Standard" : "Low"), rate: \(String(format: "%.2f", frameRateMode == 0 ? frameRate : lowFrameRate)) fps")
                print("Timeline: Total thumbnails: \(timelineThumbnails.count)")
                
                // Update timeline duration if needed
                if currentTime > timelineTotalDuration {
                    timelineTotalDuration = currentTime + 10  // Add 10 seconds margin
                }
            }

            // Update current position regardless of capture
            timelineCurrentPosition = currentTime
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
        guard isAudioRecording, !audioBuffers.isEmpty else { return }
        
        let totalSize = audioBuffers.reduce(0) { $0 + $1.count }
        let sizeMB = totalSize / (1024 * 1024)
        
        // @MainActor does not require DispatchQueue.main.async
        memoryUsageMessage = "Memory Usage: \(sizeMB)MB (\(audioBuffers.count) buffers)"
        
        // Warn if memory usage is too high
        if sizeMB > 500 {
            errorMessage = "Warning: Memory usage is high (\(sizeMB)MB). Stop capturing and save."
        }
    }

    // Method to enable/disable timeline capturing
    public func toggleTimelineCapturing(_ enabled: Bool) {
        isTimelineCapturingEnabled = enabled
        if !enabled {
            // Reset timeline data when disabled
            timelineAudioSamples = []
            timelineThumbnails = []
            timelineCurrentPosition = 0
        } else {
            // Reset the starting time and force immediate thumbnail capture
            lastThumbnailTime = 0
            timelineCurrentPosition = 0
            
            // Debug information
            print("Timeline recording started with interval: \(String(format: "%.2f", thumbnailInterval))s")
            print("Frame rate: \(frameRateMode == 0 ? frameRate : lowFrameRate) fps")
        }
    }

    // Helper method to extract PCM samples from raw audio data
    private func extractPCMSamples(from audioBuffer: Data, channelCount: Int) -> [Float] {
        // If the buffer is too small, return empty array
        if audioBuffer.count < 4 {
            return []
        }
        
        let samplesPerChannel = audioBuffer.count / (4 * channelCount) // 4 bytes per Float32 sample
        var result: [Float] = []
        result.reserveCapacity(samplesPerChannel)
        
        // Downsample for efficiency - we don't need all samples for visualization
        let step = max(1, samplesPerChannel / 200) // Limit to ~200 samples
        
        // Extract samples for first channel only (for visualization)
        for i in stride(from: 0, to: samplesPerChannel * channelCount, by: step * channelCount) {
            let sampleIndex = i * 4 // 4 bytes per Float32
            if sampleIndex + 4 <= audioBuffer.count {
                var value: Float = 0
                audioBuffer.withUnsafeBytes { rawBufferPointer in
                    let buffer = rawBufferPointer.bindMemory(to: Float.self)
                    if sampleIndex / 4 < buffer.count {
                        value = buffer[sampleIndex / 4]
                    }
                }
                // Clamp value to prevent extreme outliers
                value = min(1.0, max(-1.0, value))
                result.append(value)
            }
        }
        
        return result
    }

    // Play from specified position
    func playFromPosition(_ position: TimeInterval) {
        guard !isCapturing else {
            errorMessage = "Playback is possible after capture stops"
            return
        }
        
        do {
            // Stop existing playback
            stopPlayback()
            
            // Set playback start position
            timelineCurrentPosition = position
            playbackOffset = position
            playbackStartTime = Date().timeIntervalSinceReferenceDate - position
            
            // Prepare PCM audio data
            prepareAudioPlayback(startPosition: position)
            
            // Display image at specified position
            updatePreviewImageForPosition(position)
            
            // Start playback
            startPlayback()
            
            isPlaying = true
        } catch {
            errorMessage = "Failed to start playback: \(error.localizedDescription)"
        }
    }

    // Stop playback
    func stopPlayback() {
        if isPlaying {
            audioPlayerNode?.stop()
            audioEngine?.stop()
            
            // Stop timer
            playbackTimer?.invalidate()
            playbackTimer = nil
            
            isPlaying = false
        }
    }

    // Prepare audio playback
    private func prepareAudioPlayback(startPosition: TimeInterval) {
        // Initialize AVAudioEngine
        audioEngine = AVAudioEngine()
        audioPlayerNode = AVAudioPlayerNode()
        
        guard let engine = audioEngine, 
              let playerNode = audioPlayerNode else { return }
        
        // Set PCM format (Float32, same channel count as captured)
        // Correct interleaved setting
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(audioSampleRate),
            channels: AVAudioChannelCount(audioChannelCount),
            interleaved: true)  // Change interleaved to true
        
        guard let format = format else {
            errorMessage = "Failed to create audio format"
            return
        }
        
        // Load saved PCM data
        guard let fileURL = audioFileURL, 
              let audioData = try? Data(contentsOf: fileURL) else {
            errorMessage = "Failed to load audio data"
            return
        }
        
        // Calculate start position (byte position)
        let bytesPerSecond = Int(audioSampleRate) * audioChannelCount * 4  // 4 bytes per Float32 sample
        let startBytePosition = min(Int(startPosition) * bytesPerSecond, audioData.count)
        
        // Prepare data after specified position
        let playData = audioData.subdata(in: startBytePosition..<audioData.count)
        
        // Create buffer - set capacity appropriately
        let bytesPerFrameInt = Int(format.streamDescription.pointee.mBytesPerFrame)
        let frameCountInt = playData.count / bytesPerFrameInt
        
        // Limit buffer size to avoid being too large
        let maxFrames = 48000 * 10 // Limit to 10 seconds
        let limitedFrameCount = min(frameCountInt, maxFrames)
        
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(limitedFrameCount))
        
        guard let buffer = buffer else {
            errorMessage = "Failed to create audio buffer"
            return
        }
        
        // Set frame length
        buffer.frameLength = AVAudioFrameCount(UInt32(limitedFrameCount))
        
        // Copy data to buffer (correct for interleaved format)
        if let audioBufferPointer = buffer.audioBufferList.pointee.mBuffers.mData {
            playData.withUnsafeBytes { rawBufferPointer in
                let floatBuffer = rawBufferPointer.bindMemory(to: Float.self)
                let audioBuffer = UnsafeMutableRawPointer(audioBufferPointer)
                
                // Directly copy interleaved data
                let bytesToCopy = min(Int(buffer.frameCapacity * buffer.format.streamDescription.pointee.mBytesPerFrame),
                                     playData.count)
                memcpy(audioBuffer, floatBuffer.baseAddress, bytesToCopy)
            }
        }
        
        // Set up AudioEngine
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        
        do {
            // Prepare audio session
            try engine.start()
            
            // Schedule and play
            playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts) {
                DispatchQueue.main.async { [weak self] in
                    self?.isPlaying = false
                }
            }
        } catch {
            errorMessage = "Failed to start audio engine: \(error.localizedDescription)"
            print("Audio engine error: \(error)")
            return
        }
    }

    // Start playback and set up timer for time updates
    private func startPlayback() {
        // Start audio playback
        audioPlayerNode?.play()
        
        // Use MainActor task in timer callback
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            // Explicitly execute on main thread using MainActor task
            Task { @MainActor [weak self] in
                self?.updatePlaybackPosition()
            }
        }
        RunLoop.current.add(playbackTimer!, forMode: .common)
    }

    // Update playback position (called from CADisplayLink)
    private func updatePlaybackPosition() {
        guard isPlaying else { return }
        
        // Calculate current playback position
        let currentTime = Date().timeIntervalSinceReferenceDate - playbackStartTime
        timelineCurrentPosition = currentTime
        
        // Update corresponding image
        updatePreviewImageForPosition(currentTime)
        
        // Check for end of playback
        if timelineCurrentPosition >= timelineTotalDuration {
            stopPlayback()
        }
    }

    // Display the capture image closest to the specified position
    func updatePreviewImageForPosition(_ position: TimeInterval) {
        // Find the closest thumbnail
        guard !timelineThumbnails.isEmpty else { return }
        
        var closestThumbnail = timelineThumbnails[0]
        var minTimeDiff = abs(timelineThumbnails[0].timestamp - position)
        
        for thumbnail in timelineThumbnails {
            let timeDiff = abs(thumbnail.timestamp - position)
            if timeDiff < minTimeDiff {
                minTimeDiff = timeDiff
                closestThumbnail = thumbnail
            }
        }
        
        // Update preview image
        previewImage = closestThumbnail.image
    }
}
