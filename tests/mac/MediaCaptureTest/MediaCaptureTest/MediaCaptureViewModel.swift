import SwiftUI
import Combine
import AVFoundation
import ScreenCaptureKit

@MainActor
class MediaCaptureViewModel: ObservableObject {
    // キャプチャ設定
    @Published var selectedTargetIndex = 0
    @Published var selectedQuality = 0
    @Published var frameRate: Double = 30.0
    @Published var audioOnly = false
    @Published var searchText = ""
    @Published var frameRateMode = 0  // 0: 標準, 1: 低速
    @Published var lowFrameRate: Double = 0.2  // デフォルトは5秒ごと(0.2fps)
    
    // キャプチャ対象
    @Published var availableTargets: [MediaCaptureTarget] = []
    @Published var isLoading = false
    
    // キャプチャ状態
    @Published var errorMessage: String? = nil
    @Published var statusMessage: String = "準備完了"
    
    // 統計情報
    @Published var frameCount = 0
    @Published var currentFPS: Double = 0
    @Published var imageSize = "-"
    @Published var audioSampleRate: Double = 0
    @Published var captureLatency: Double = 0
    @Published var audioLevel: Float = 0
    
    // プレビュー
    @Published var previewImage: NSImage? = nil
    
    // フレームレート計算用
    private var lastFrameTime = Date()
    private var frameCountInLastSecond = 0
    
    // メディアキャプチャ
    private var mediaCapture = MediaCapture()
    private var fpsUpdateTimer: Timer? = nil
    
    // 音声波形表示用の履歴データ (最大100サンプル)
    @Published var audioLevelHistory: [Float] = Array(repeating: 0, count: 100)
    
    // 音声キャプチャ関連
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
    
    // MainActorから分離されたアクセスのためのバッキングプロパティ
    // 手動で並行処理安全性を管理することを明示
    nonisolated(unsafe) private var _isCapturingStorage: Bool = false

    // MainActor分離プロパティ
    var isCapturing: Bool {
        get { _isCapturingStorage }
        set { _isCapturingStorage = newValue }
    }

    // 分離されていない読み取り専用プロパティ
    nonisolated var isCapturingNonisolated: Bool {
        _isCapturingStorage
    }

    var filteredTargets: [MediaCaptureTarget] {
        if searchText.isEmpty {
            return availableTargets
        } else {
            return availableTargets.filter { target in
                let title = target.title ?? ""
                let appName = target.applicationName ?? ""
                return title.localizedCaseInsensitiveContains(searchText) || 
                       appName.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    // init メソッドでのエラーチェックも nonisolated を使用
    init() {
        // nonisolated コンテキストからプロパティの値を安全に取得するため、
        // TimerのクロージャをSendable準拠にする
        fpsUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // キャプチャする参照がnilの場合は何もしない
            guard let self = self else { return }
            
            // isCapturing の状態をチェックする前に判断
            let isCurrentlyCapturing = self.isCapturingNonisolated
            if (!isCurrentlyCapturing) {
                return
            }
            
            // MainActorコンテキストでプロパティにアクセス
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
        print("MediaCaptureViewModelがdeinitされました")
        
        // タイマーをクリア
        fpsUpdateTimer?.invalidate()
        fpsUpdateTimer = nil
        
        audioRecordingTimer?.invalidate()
        audioRecordingTimer = nil
        
        // 音声バッファをクリア
        audioBuffers.removeAll()
        
        // 同期的にキャプチャを停止
        // nonisolated プロパティを使用
        let capture = mediaCapture
        let wasCapturing = isCapturingNonisolated // ここを修正
        
        // MainActorコンテキスト外で実行可能なコードのみ
        if wasCapturing {
            capture.stopCaptureSync()
            
            // UIの状態は更新不可（deinit中のため）
            print("deinit: キャプチャを停止しました")
        }
    }
    
    // 利用可能なキャプチャ対象を読み込む
    func loadAvailableTargets() async {
        // @MainActorなのでDispatchQueue.main.asyncが不要
        isLoading = true
        errorMessage = nil
        
        do {
            let targets = try await MediaCapture.availableWindows()
            // @MainActorなのでDispatchQueue.main.asyncが不要
            self.availableTargets = targets
            self.isLoading = false
            if targets.isEmpty {
                self.errorMessage = "利用可能なキャプチャ対象が見つかりませんでした。"
            }
        } catch {
            // @MainActorなのでDispatchQueue.main.asyncが不要
            self.isLoading = false
            self.errorMessage = "キャプチャ対象の読み込み中にエラーが発生しました: \(error.localizedDescription)"
        }
    }
    
    // キャプチャを開始する
    func startCapture() async {
        guard !isCapturing, !availableTargets.isEmpty, selectedTargetIndex < filteredTargets.count else { 
            // @MainActorなのでDispatchQueue.main.asyncが不要
            errorMessage = "選択されたキャプチャ対象が無効です。"
            return
        }
        
        // UI状態を初期化
        errorMessage = nil
        statusMessage = "キャプチャを準備中..."
        frameCount = 0
        currentFPS = 0
        frameCountInLastSecond = 0
        lastFrameTime = Date()
        
        // 選択したターゲット
        let selectedTarget = filteredTargets[selectedTargetIndex]
        
        // 品質設定
        let quality: MediaCapture.CaptureQuality
        switch selectedQuality {
            case 0: quality = .high
            case 1: quality = .medium
            default: quality = .low
        }
        
        // フレームレート設定
        let fps = audioOnly ? 0.0 : (frameRateMode == 0 ? frameRate : lowFrameRate)
        
        do {
            // キャプチャを開始 - ここが重要な変更ポイント
            let success = try await mediaCapture.startCapture(
                target: selectedTarget,
                mediaHandler: { [weak self] media in
                    // @SendableクロージャからMainActorメソッドを呼ぶために
                    // Task { @MainActor in ... } を使用
                    Task { @MainActor [weak self] in
                        self?.processMedia(media)
                    }
                },
                errorHandler: { [weak self] errorMessage in
                    // @SendableクロージャからMainActorプロパティを更新するために
                    // Task { @MainActor in ... } を使用
                    Task { @MainActor [weak self] in
                        self?.errorMessage = errorMessage
                    }
                },
                framesPerSecond: fps,
                quality: quality
            )
            
            // @MainActorなのでDispatchQueue.main.asyncが不要
            if success {
                isCapturing = true
                statusMessage = "キャプチャ中..."
                print("キャプチャ開始: isCapturing = \(isCapturing)")
                startAudioRecording()
            } else {
                errorMessage = "キャプチャの開始に失敗しました"
                statusMessage = "準備完了"
            }
        } catch {
            // @MainActorなのでDispatchQueue.main.asyncが不要
            errorMessage = "キャプチャ開始エラー: \(error.localizedDescription)"
            statusMessage = "準備完了"
        }
    }
    
    // キャプチャを停止する
    func stopCapture() async {
        guard isCapturing else { return }
        
        // 状態更新
        statusMessage = "キャプチャを停止中..."
        
        // 音声録音を停止
        if isAudioRecording {
            stopAudioRecording()
        }
        
        // キャプチャ停止
        mediaCapture.stopCaptureSync()
        
        // UI更新 - @MainActorなのでDispatchQueue.main.asyncが不要
        isCapturing = false
        previewImage = nil
        frameCountInLastSecond = 0
        currentFPS = 0
        statusMessage = "キャプチャが停止しました"
        print("キャプチャ停止: isCapturing = \(isCapturing)")
    }
    
    // 音声記録を開始
    func startAudioRecording() {
        guard isCapturing, !isAudioRecording else { return }
        
        // バッファ初期化
        audioBuffers.removeAll()
        audioFileURL = nil
        audioRecordingTime = 0
        audioRecordingStartTime = Date()
        isAudioRecording = true
        
        // 録音時間更新タイマー - Timerクロージャは非分離コンテキストとして扱われる
        audioRecordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            // MainActorコンテキストでプロパティにアクセス
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // audioRecordingStartTimeがnilの場合もスキップ
                guard let startTime = self.audioRecordingStartTime else { return }
                
                self.audioRecordingTime = Date().timeIntervalSince(startTime)
                
                // 簡易的なバッファサイズチェック
                if self.audioRecordingTime.truncatingRemainder(dividingBy: 10) < 0.1 {
                    self.checkMemoryUsage()
                }
            }
        }
    }
    
    // 音声記録を停止して保存
    func stopAudioRecording() {
        guard isAudioRecording else { return }
        
        // タイマー停止
        audioRecordingTimer?.invalidate()
        audioRecordingTimer = nil
        isAudioRecording = false
        
        // 保存処理
        saveAudioToFile()
    }
    
    // 音声データをファイルに保存する処理の修正
    private func saveAudioToFile() {
        guard !audioBuffers.isEmpty else {
            errorMessage = "保存する音声データがありません"
            return
        }
        
        // 保存先のファイルパスを作成
        let tempDir = FileManager.default.temporaryDirectory
        
        // ディレクトリが存在することを確認
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            print("ディレクトリ作成エラー: \(error)")
        }
        
        let fileName = "audio_capture_\(Int(Date().timeIntervalSince1970)).pcm"
        let fileURL = tempDir.appendingPathComponent(fileName)
        
        do {
            // データサイズの警告
            let totalSize = audioBuffers.reduce(0) { $0 + $1.count }
            print("保存中: \(totalSize / (1024 * 1024))MB のオーディオデータ")
            
            // 最初に空のファイルを作成
            try Data().write(to: fileURL)
            
            // バッファを効率的に一つずつ書き込む
            let fileHandle = try FileHandle(forWritingTo: fileURL)
            defer { 
                try? fileHandle.close()
            }
            
            // バッファを一つずつ書き込む
            let totalBuffers = audioBuffers.count
            for (index, buffer) in audioBuffers.enumerated() {
                try fileHandle.write(contentsOf: buffer)
                
                // 進捗報告（10%ごと）
                if index % max(1, totalBuffers / 10) == 0 || index == totalBuffers - 1 {
                    let progress = Double(index + 1) / Double(totalBuffers) * 100
                    print("保存進捗: \(Int(progress))%")
                }
            }
            
            // バッファをクリア（メモリ解放）
            audioBuffers.removeAll()
            
            // 成功
            audioFileURL = fileURL
            
            // フォーマット情報を更新
            updateAudioFormatDescription()
            errorMessage = "音声ファイルを保存しました: \(fileURL.lastPathComponent)"
            
            print("FFplay command: \(getFFplayCommand())")
        } catch {
            print("ファイル保存エラー: \(error)")
            errorMessage = "音声ファイルの書き込みに失敗しました: \(error.localizedDescription)"
        }
    }
    
    // ffplayで再生するためのコマンドを生成
    private func generateFFplayCommand(format: AVAudioFormat, fileURL: URL) -> String {
        let sampleRate = Int(format.sampleRate)
        let channels = Int(format.channelCount)
        let isFloat = format.commonFormat == .pcmFormatFloat32        
        let chLayout = channels == 2 ? "stereo" : "mono"
        return "ffplay -f \(isFloat ? "f32le" : "s16le") -ar \(sampleRate) -ch_layout \(chLayout) \"\(fileURL.path)\""
    }
    
    // オーディオフォーマット情報の文字列を更新（シンプル化）
    private func updateAudioFormatDescription() {
        // フォーマット情報を構築
        var formatInfo = [String]()
        formatInfo.append("サンプルレート: \(Int(audioSampleRate)) Hz")
        formatInfo.append("チャンネル数: \(audioChannelCount)")
        formatInfo.append("ビット深度: 32ビット浮動小数点")
        formatInfo.append("フォーマット: PCM Float32 リトルエンディアン")
        formatInfo.append("ffplayコマンド: ffplay -f f32le -ar \(Int(audioSampleRate)) -ac \(audioChannelCount) \"ファイル名\"")
        
        audioFormatDescription = formatInfo.joined(separator: "\n")
    }
    
    // ffplayコマンドを生成
    func getFFplayCommand() -> String {
        guard let url = audioFileURL else { return "" }
        return "ffplay -f f32le -ar \(Int(audioSampleRate)) -ac \(audioChannelCount) \"\(url.path)\""
    }

    // 音声データをモノラルに変換して保存する
    func saveAudioToMonoFile() {
        guard !audioBuffers.isEmpty else {
            errorMessage = "保存する音声データがありません"
            return
        }
        
        // バッファがすでに保存されていない場合のみ実行
        guard let originalURL = audioFileURL else {
            errorMessage = "先に録音を停止して保存してください"
            return
        }
        
        // 保存先のファイルパスを作成
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "audio_mono_\(Int(Date().timeIntervalSince1970)).pcm"
        let fileURL = tempDir.appendingPathComponent(fileName)
        
        do {
            // ステレオ→モノラル変換の進捗表示
            statusMessage = "モノラル変換中..."
            
            // 32ビット浮動小数点なので4バイトを1サンプルとして処理
            let bytesPerSample = 4
            
            // 既に保存されたファイルからデータを読み込む
            let fileData = try Data(contentsOf: originalURL)
            let totalSamples = fileData.count / bytesPerSample
            
            // ファイルハンドル作成
            try Data().write(to: fileURL)
            let fileHandle = try FileHandle(forWritingTo: fileURL)
            defer { try? fileHandle.close() }
            
            // バッファサイズ（チャンクサイズ）
            let bufferSize = 1024 * 1024 // 1MB
            let samplesPerBuffer = bufferSize / bytesPerSample
            let totalBuffers = (totalSamples + samplesPerBuffer - 1) / samplesPerBuffer
            
            print("モノラル変換を開始します: 合計サンプル数=\(totalSamples), バッファ数=\(totalBuffers)")
            
            // ステレオの場合、チャンネル数が2の場合
            if audioChannelCount == 2 {
                // 変換済みサンプル数をカウント
                var processedSamples = 0
                
                for bufferIndex in 0..<totalBuffers {
                    let startSample = bufferIndex * samplesPerBuffer
                    let endSample = min(startSample + samplesPerBuffer, totalSamples)
                    let currentSamples = endSample - startSample
                    
                    var monoBuffer = Data(capacity: currentSamples * bytesPerSample / 2)
                    
                    for i in 0..<(currentSamples / 2) {
                        let stereoIndex = startSample + i * 2
                        
                        // 左右チャンネルのインデックス
                        let leftIdx = stereoIndex * bytesPerSample
                        let rightIdx = (stereoIndex + 1) * bytesPerSample
                        
                        if leftIdx + bytesPerSample <= fileData.count && rightIdx + bytesPerSample <= fileData.count {
                            // 左右チャンネルのデータを取得
                            let leftBytes = fileData[leftIdx..<leftIdx+bytesPerSample]
                            let rightBytes = fileData[rightIdx..<rightIdx+bytesPerSample]
                            
                            // Float32に変換
                            var leftValue: Float = 0
                            var rightValue: Float = 0
                            
                            (leftBytes as NSData).getBytes(&leftValue, length: bytesPerSample)
                            (rightBytes as NSData).getBytes(&rightValue, length: bytesPerSample)
                            
                            // 左右の平均を取る
                            let monoValue = (leftValue + rightValue) / 2.0
                            
                            // Float32をバイト列に変換
                            var monoBytes = monoValue
                            monoBuffer.append(Data(bytes: &monoBytes, count: bytesPerSample))
                            
                            processedSamples += 2
                        }
                    }
                    
                    // バッファをファイルに書き込み
                    fileHandle.write(monoBuffer)
                    
                    // 進捗報告
                    let progress = Double(processedSamples) / Double(totalSamples) * 100
                    if bufferIndex % 10 == 0 || bufferIndex == totalBuffers - 1 {
                        print("モノラル変換進捗: \(Int(progress))%")
                    }
                }
            } else {
                // すでにモノラルの場合はそのままコピー
                fileHandle.write(fileData)
            }
            
            // UI更新
            statusMessage = "モノラル変換完了"
            errorMessage = "モノラル音声ファイルを保存しました: \(fileURL.lastPathComponent)"
            
            // ffplayコマンドを生成（モノラル用）
            let ffplayCommand = "ffplay -f f32le -ar \(Int(audioSampleRate)) -ac 1 \"\(fileURL.path)\""
            print("モノラルファイルを保存しました: \(fileURL.path)")
            print("FFplay command (mono): \(ffplayCommand)")
            
        } catch {
            statusMessage = "準備完了"
            errorMessage = "モノラル変換失敗: \(error.localizedDescription)"
        }
    }

    // 既存のFFplayコマンド取得関数に加えて、モノラル用も追加
    func getMonoFFplayCommand() -> String {
        guard let url = audioFileURL else { return "" }
        return "ffplay -f f32le -ar \(Int(audioSampleRate)) -ac 1 \"\(url.path)\""
    }


    // メディアデータを処理する
    private func processMedia(_ media: StreamableMediaData) {
        // @MainActorなので、このメソッド内のコードは既にメインスレッドで実行されている
        
        // オーディオ情報の処理
        if let audioInfo = media.metadata.audioInfo {
            // フォーマット情報を取得
            audioSampleRate = audioInfo.sampleRate
            audioChannelCount = audioInfo.channelCount
            
            // 録音中ならバッファに追加
            if isAudioRecording, let audioBuffer = media.audioBuffer {
                audioBuffers.append(audioBuffer)
            }
        }
        
        // 遅延を計算
        let now = Date().timeIntervalSince1970
        let latency = (now - media.metadata.timestamp) * 1000 // ミリ秒
        captureLatency = latency
        
        // ビデオフレーム処理
        if let videoBuffer = media.videoBuffer, let videoInfo = media.metadata.videoInfo {
            // 映像サイズを更新
            imageSize = "\(videoInfo.width) × \(videoInfo.height)"
            
            // フレームカウントを更新
            frameCount += 1
            frameCountInLastSecond += 1
            
            // プレビュー画像を更新（フレームレート削減のため間引く）
            if frameCount % 5 == 0 {  // 5フレームに1回だけ更新
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
        
        // オーディオレベル処理
        if let audioBuffer = media.audioBuffer, audioBuffer.count > 0 {
            // 単純な実装
            let audioSamples = [UInt8](audioBuffer)
            var sum: Float = 0
            
            // サンプル数を制限
            let step = max(1, audioSamples.count / 50)
            for i in stride(from: 0, to: audioSamples.count, by: step) {
                let sample = Float(audioSamples[i]) / 255.0
                sum += sample * sample
            }
            
            let rms = sqrt(sum / Float(audioSamples.count / step))
            audioLevel = min(rms * 5, 1.0)
            
            // 音声レベル履歴を更新
            if frameCount % 3 == 0 {
                audioLevelHistory.removeFirst()
                audioLevelHistory.append(audioLevel)
            }
        }
    }
    
    // ビデオバッファをNSImageに変換
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
    
    // 記録中のメモリ使用量チェックを分離（シンプル版）
    private func checkMemoryUsage() {
        guard isAudioRecording, !audioBuffers.isEmpty else { return }
        
        let totalSize = audioBuffers.reduce(0) { $0 + $1.count }
        let sizeMB = totalSize / (1024 * 1024)
        
        // @MainActorなのでDispatchQueue.main.asyncが不要
        memoryUsageMessage = "メモリ使用量: \(sizeMB)MB (\(audioBuffers.count)バッファ)"
        
        // メモリ使用量が多すぎる場合は警告
        if sizeMB > 500 {
            errorMessage = "警告: メモリ使用量が多いです(\(sizeMB)MB)。キャプチャを停止して保存してください。"
        }
    }
}
