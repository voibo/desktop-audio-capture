import Foundation
import AppKit
import AVFoundation
import Combine

// フレームプレビュー用ViewModel
class FramePreviewViewModel: NSObject, ObservableObject {
    // 基本セッション管理
    @Published var sessions: [(name: String, url: URL)] = []
    @Published var selectedSessionIndex: Int = 0
    @Published var isLoading: Bool = false
    @Published var sessionMetadata: [String: Any]? = nil
    
    // フレーム関連プロパティ
    @Published var frames: [FrameInfo] = []
    @Published var selectedFrameIndex: Int = 0 {
        didSet {
            loadSelectedFrameImage()
        }
    }
    @Published var previewImage: NSImage? = nil
    
    // 音声再生関連プロパティ
    @Published var isPlaying: Bool = false
    @Published var playbackPosition: Double = 0
    @Published var audioDuration: Double = 0
    @Published var audioWaveform: [Float] = []
    @Published var isConverting: Bool = false
    @Published var statusMessage: String? = nil
    @Published var isStatusError: Bool = false
    @Published var ffplayCommand: String = ""
    
    // 共有リソース
    private let dataManager = RawDataManager()
    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    // フレーム情報構造体を拡張
    struct FrameInfo {
        let frameNumber: Int
        let relativeTime: Double
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let pixelFormat: UInt32
        let filename: String
        let format: String?       // "jpeg" または "raw"
        let quality: Float?       // JPEG品質設定（0.0-1.0）
    }
    
    // フォーマット情報用のプロパティを追加
    struct FormatInfo {
        let format: String
        let quality: Float?
    }
    
    override init() {
        super.init()
        // 初期化時に必要なセットアップを行う
    }
    
    deinit {
        stopPlaybackTimer()
        audioPlayer?.stop()
    }
    
    // MARK: - セッション管理
    
    var selectedFrame: FrameInfo? {
        guard selectedFrameIndex >= 0 && selectedFrameIndex < frames.count else {
            return nil
        }
        return frames[selectedFrameIndex]
    }
    
    // 選択中のフレームのフォーマット情報を取得するプロパティ
    var selectedFrameFormatInfo: FormatInfo? {
        guard let frame = selectedFrame else { return nil }
        
        let format = frame.format ?? "raw"
        return FormatInfo(format: format, quality: frame.quality)
    }
    
    // 利用可能なセッションの読み込み
    func loadSessions() {
        print("DEBUG: セッションの読み込みを開始...")
        
        // セッションリストを取得
        let availableSessions = dataManager.getSavedSessions()
        
        sessions = availableSessions
        print("DEBUG: 読み込まれたセッション数: \(sessions.count)")
        
        // インデックスの調整（空でなければ）
        if (!sessions.isEmpty) {
            // インデックスが範囲外なら0に設定
            if (selectedSessionIndex >= sessions.count) {
                selectedSessionIndex = 0
            }
            
            // 最初のセッションを自動的に選択して読み込む
            Task {
                await loadSelectedSession()
            }
        } else {
            print("DEBUG: 利用可能なセッションがありません")
            // UIメッセージの設定
            statusMessage = "キャプチャセッションが見つかりません"
            isStatusError = true
        }
    }
    
    // 選択されたセッションのメタデータとフレーム情報を読み込む
    @MainActor
    func loadSelectedSession() async {
        guard !sessions.isEmpty && selectedSessionIndex < sessions.count else {
            sessionMetadata = nil
            frames = []
            return
        }
        
        isLoading = true
        defer { isLoading = false }
        
        let sessionUrl = sessions[selectedSessionIndex].url
        let metadataUrl = sessionUrl.appendingPathComponent("capture_metadata.json")
        
        do {
            // メタデータ読み込み
            let data = try Data(contentsOf: metadataUrl)
            sessionMetadata = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            
            // フレーム情報の抽出
            await loadFrameInfo()
            
            // 音声情報の抽出
            loadAudioInfo()
            
            // 波形データの生成（バックグラウンド）
            Task.detached(priority: .background) {
                await self.generateAudioWaveform()
            }
            
        } catch {
            sessionMetadata = nil
            frames = []
            print("メタデータ読み込みエラー: \(error)")
        }
    }
    
    // MARK: - フレーム関連メソッド
    
    @MainActor
    private func loadFrameInfo() async {
        guard let framesArray = sessionMetadata?["frames"] as? [[String: Any]] else {
            frames = []
            return
        }
        
        var frameInfoList: [FrameInfo] = []
        for frameDict in framesArray {
            if let frameNumber = frameDict["frameNumber"] as? Int,
               let relativeTime = frameDict["relativeTime"] as? Double,
               let width = frameDict["width"] as? Int,
               let height = frameDict["height"] as? Int,
               let bytesPerRow = frameDict["bytesPerRow"] as? Int,
               let pixelFormat = frameDict["pixelFormat"] as? UInt32,
               let filename = frameDict["filename"] as? String {
                
                // 新しいフィールドを読み込み（オプショナル）
                let format = frameDict["format"] as? String
                let quality = frameDict["quality"] as? Float
                
                frameInfoList.append(
                    FrameInfo(
                        frameNumber: frameNumber,
                        relativeTime: relativeTime,
                        width: width,
                        height: height,
                        bytesPerRow: bytesPerRow,
                        pixelFormat: pixelFormat,
                        filename: filename,
                        format: format,
                        quality: quality
                    )
                )
            }
        }
        
        frames = frameInfoList.sorted { $0.frameNumber < $1.frameNumber }
        selectedFrameIndex = 0
        
        // 最初のフレームを読み込む
        if !frames.isEmpty {
            loadSelectedFrameImage()
        }
    }
    
    // 選択されたフレームの画像を読み込む
    private func loadSelectedFrameImage() {
        guard let frame = selectedFrame,
              !sessions.isEmpty && selectedSessionIndex < sessions.count else {
            previewImage = nil
            return
        }
        
        let sessionUrl = sessions[selectedSessionIndex].url
        let frameUrl = sessionUrl.appendingPathComponent("frames").appendingPathComponent(frame.filename)
        
        // フォーマットに基づいて適切な読み込み処理を行う
        if let format = frame.format, format == "jpeg" {
            // JPEGはそのまま読み込む
            if let image = NSImage(contentsOf: frameUrl) {
                previewImage = image
                return
            }
        }
        
        // rawデータまたはJPEG読み込み失敗時はバイナリデータとして処理
        previewImage = dataManager.loadFrameImage(
            frameFile: frameUrl,
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow
        )
    }
    
    // MARK: - 音声関連メソッド
    
    // 音声情報の読み込み
    private func loadAudioInfo() {
        guard let audioInfo = sessionMetadata?["audioInfo"] as? [String: Any],
              let filename = audioInfo["filename"] as? String,
              let sampleRate = audioInfo["sampleRate"] as? Double else {
            return
        }
        
        let sessionUrl = sessions[selectedSessionIndex].url
        let audioUrl = sessionUrl.appendingPathComponent(filename)
        
        // ffplayコマンド生成
        let channelCount = audioInfo["channelCount"] as? Int ?? 2
        ffplayCommand = "ffplay -f f32le -ar \(Int(sampleRate)) -ac \(channelCount) \"\(audioUrl.path)\""
    }
    
    // 波形データの生成
    @MainActor
    private func generateAudioWaveform() async {
        guard let audioInfo = sessionMetadata?["audioInfo"] as? [String: Any],
              let filename = audioInfo["filename"] as? String,
              let _ = audioInfo["sampleRate"] as? Double else {
            return
        }
        
        let sessionUrl = sessions[selectedSessionIndex].url
        let audioUrl = sessionUrl.appendingPathComponent(filename)
        
        // ファイルデータを読み込む
        guard let audioData = try? Data(contentsOf: audioUrl) else {
            return
        }
        
        // サンプル分析パラメータ
        let channelCount = audioInfo["channelCount"] as? Int ?? 2
        let bytesPerSample = 4 // Float32 = 4バイト
        let samplesPerChannel = audioData.count / bytesPerSample / channelCount
        
        // 表示用のサンプル数を決定（最大1000ポイント）
        let waveformPoints = 1000
        let samplesPerPoint = max(1, samplesPerChannel / waveformPoints)
        
        // 波形データ配列
        var waveform = [Float](repeating: 0, count: min(waveformPoints, samplesPerChannel))
        
        // サンプルを処理
        audioData.withUnsafeBytes { rawBufferPointer in
            let floatBuffer = rawBufferPointer.bindMemory(to: Float.self)
            
            for point in 0..<waveform.count {
                var maxMagnitude: Float = 0
                
                // 各ポイントに対応するサンプル範囲で最大振幅を探す
                let startSample = point * samplesPerPoint
                let endSample = min(startSample + samplesPerPoint, samplesPerChannel)
                
                for sampleIdx in startSample..<endSample {
                    for channel in 0..<channelCount {
                        let bufferIdx = sampleIdx * channelCount + channel
                        if bufferIdx < floatBuffer.count {
                            let magnitude = abs(floatBuffer[bufferIdx])
                            maxMagnitude = max(maxMagnitude, magnitude)
                        }
                    }
                }
                
                waveform[point] = min(1.0, maxMagnitude) // 0-1の範囲に正規化
            }
        }
        
        await MainActor.run {
            audioWaveform = waveform
        }
    }
    
    // 再生/停止の切り替え
    func toggleAudioPlayback() {
        if isPlaying {
            stopAudioPlayback()
        } else {
            startAudioPlayback()
        }
    }
    
    // 音声再生開始
    private func startAudioPlayback() {
        guard let audioInfo = sessionMetadata?["audioInfo"] as? [String: Any],
              let filename = audioInfo["filename"] as? String,
              let sampleRate = audioInfo["sampleRate"] as? Double else {
            return
        }
        
        let sessionUrl = sessions[selectedSessionIndex].url
        let audioUrl = sessionUrl.appendingPathComponent(filename)
        
        // PCMデータを一時AVAudioファイルに変換して再生
        do {
            let data = try Data(contentsOf: audioUrl)
            let tempWavUrl = FileManager.default.temporaryDirectory.appendingPathComponent("temp_preview.wav")
            
            // PCMデータをWAVに変換
            let channelCount = audioInfo["channelCount"] as? Int ?? 2
            try convertPCMToWAV(
                pcmData: data,
                outputURL: tempWavUrl,
                sampleRate: sampleRate,
                channels: UInt32(channelCount)
            )
            
            // 再生
            audioPlayer = try AVAudioPlayer(contentsOf: tempWavUrl)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            isPlaying = true
            audioDuration = audioPlayer?.duration ?? 0
            startPlaybackTimer()
        } catch {
            statusMessage = "再生エラー: \(error.localizedDescription)"
            isStatusError = true
            print("音声再生エラー: \(error)")
        }
    }
    
    // PCMデータをWAVに変換する
    private func convertPCMToWAV(pcmData: Data, outputURL: URL, sampleRate: Double, channels: UInt32) throws {
        do {
            // 既存のファイルを削除
            try? FileManager.default.removeItem(at: outputURL)
            
            // 設定
            var format = AudioStreamBasicDescription()
            format.mSampleRate = Float64(sampleRate)
            format.mFormatID = kAudioFormatLinearPCM
            format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            format.mBitsPerChannel = 32
            format.mChannelsPerFrame = channels
            format.mBytesPerFrame = format.mChannelsPerFrame * 4
            format.mFramesPerPacket = 1
            format.mBytesPerPacket = format.mBytesPerFrame * format.mFramesPerPacket
            
            // 一時ファイル作成
            var audioFile: ExtAudioFileRef?
            var status = ExtAudioFileCreateWithURL(
                outputURL as CFURL,
                kAudioFileWAVEType,
                &format,
                nil,
                AudioFileFlags.eraseFile.rawValue,
                &audioFile
            )
            
            guard status == noErr, let audioFile = audioFile else {
                throw NSError(domain: "AudioError", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "WAVファイルの作成に失敗しました"])
            }
            
            // バッファからデータを書き込む
            let bufferByteSize = pcmData.count
            let numFrames = UInt32(bufferByteSize) / (format.mBytesPerFrame)
            
            var buffer = AudioBuffer()
            buffer.mNumberChannels = format.mChannelsPerFrame
            buffer.mDataByteSize = UInt32(bufferByteSize)
            buffer.mData = UnsafeMutableRawPointer(mutating: (pcmData as NSData).bytes)
            
            var bufferList = AudioBufferList()
            bufferList.mNumberBuffers = 1
            bufferList.mBuffers = buffer
            
            status = ExtAudioFileWrite(audioFile, numFrames, &bufferList)
            if status != noErr {
                throw NSError(domain: "AudioError", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "WAVファイルの書き込みに失敗しました"])
            }
            
            // クローズ
            ExtAudioFileDispose(audioFile)
        } catch {
            throw error
        }
    }
    
    // 音声再生停止
    private func stopAudioPlayback() {
        audioPlayer?.stop()
        isPlaying = false
        stopPlaybackTimer()
    }
    
    // 再生タイマー開始
    private func startPlaybackTimer() {
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer else { return }
            self.playbackPosition = player.currentTime
        }
    }
    
    // 再生タイマー停止
    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
    
    // 再生位置の変更
    func seekToPosition(_ position: Double) {
        audioPlayer?.currentTime = position
    }
    
    // ffplayコマンドをクリップボードにコピー
    func copyFFPlayCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ffplayCommand, forType: .string)
        
        statusMessage = "ffplayコマンドをコピーしました"
        isStatusError = false
        
        // 数秒後にメッセージをクリア
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.statusMessage = nil
        }
    }
    
    // モノラルに変換
    func convertToMono() {
        guard let audioInfo = sessionMetadata?["audioInfo"] as? [String: Any],
              let filename = audioInfo["filename"] as? String else {
            return
        }
        
        let sessionUrl = sessions[selectedSessionIndex].url
        let audioUrl = sessionUrl.appendingPathComponent(filename)
        let monoUrl = sessionUrl.appendingPathComponent("mono_\(filename)")
        
        isConverting = true
        statusMessage = "変換中..."
        isStatusError = false
        
        // バックグラウンドでモノラル変換
        Task.detached {
            do {
                // 現在のオーディオデータを読み込み
                let audioData = try Data(contentsOf: audioUrl)
                
                // チャンネル数を確認
                let channelCount = audioInfo["channelCount"] as? Int ?? 0
                
                if channelCount == 2 { // ステレオの場合のみ変換
                    // ステレオをモノラルに変換
                    var monoData = Data()
                    let bytesPerSample = 4 // Float32 = 4バイト
                    
                    audioData.withUnsafeBytes { rawBufferPointer in
                        let floatBuffer = rawBufferPointer.bindMemory(to: Float.self)
                        
                        for i in stride(from: 0, to: floatBuffer.count, by: 2) {
                            if i + 1 < floatBuffer.count {
                                // 左右チャンネルの平均を取る
                                let leftSample = floatBuffer[i]
                                let rightSample = floatBuffer[i + 1]
                                let monoSample = (leftSample + rightSample) / 2.0
                                
                                // モノラルデータに追加
                                var monoFloat = monoSample
                                monoData.append(Data(bytes: &monoFloat, count: bytesPerSample))
                            }
                        }
                    }
                    
                    // 変換したデータをファイルに書き込み
                    try monoData.write(to: monoUrl)
                    
                    // 成功メッセージ
                    await MainActor.run {
                        self.isConverting = false
                        self.statusMessage = "モノラル変換が完了しました"
                        self.isStatusError = false
                    }
                } else {
                    // 既にモノラルの場合は単にコピー
                    try audioData.write(to: monoUrl)
                    await MainActor.run {
                        self.isConverting = false
                        self.statusMessage = "ファイルは既にモノラルです。コピーが完了しました"
                        self.isStatusError = false
                    }
                }
                
                // モノラル変換のffplayコマンド生成
                let sampleRate = audioInfo["sampleRate"] as? Double ?? 48000
                _ = "ffplay -f f32le -ar \(Int(sampleRate)) -ac 1 \"\(monoUrl.path)\""
                
                // Finderで表示
                await MainActor.run {
                    NSWorkspace.shared.selectFile(monoUrl.path, inFileViewerRootedAtPath: "")
                }
                
            } catch {
                await MainActor.run {
                    self.isConverting = false
                    self.statusMessage = "変換エラー: \(error.localizedDescription)"
                    self.isStatusError = true
                }
            }
        }
    }
    
    // Finderで表示
    func openInFinder() {
        guard let audioInfo = sessionMetadata?["audioInfo"] as? [String: Any],
              let filename = audioInfo["filename"] as? String else {
            return
        }
        
        let sessionUrl = sessions[selectedSessionIndex].url
        let audioUrl = sessionUrl.appendingPathComponent(filename)
        
        NSWorkspace.shared.activateFileViewerSelecting([audioUrl])
    }
    
    // Finderでフォルダを開くヘルパーメソッド
    func openCaptureFolder() {
        guard !sessions.isEmpty else { return }
        
        let baseFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MediaCaptureData")
        
        if FileManager.default.fileExists(atPath: baseFolder.path) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: baseFolder.path)
        }
    }
}

// AVAudioPlayerデリゲート
extension FramePreviewViewModel: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        stopPlaybackTimer()
    }
}
