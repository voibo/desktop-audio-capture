import Foundation
import AVFoundation
import AppKit

class RawDataManager: ObservableObject {
    // 公開プロパティ
    @Published var isEnabled: Bool = false
    @Published var isSaving: Bool = false
    @Published var captureFolder: URL?
    @Published var savedFrameCount: Int = 0
    @Published var audioBufferSize: Int = 0
    @Published var statusMessage: String = ""
    @Published var errorMessage: String? = nil
    
    // 内部プロパティ
    private var audioBuffer = Data()
    private var frameMetadata: [String: Any] = [:]
    private var captureStartTime: Date?
    private var sessionID: String = ""
    
    // キャプチャセッション初期化
    func initializeSession(frameRate: Double, quality: Int) -> Bool {
        guard isEnabled else { return false }
        
        // セッションID生成
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        
        sessionID = "capture_\(timestamp)"
        captureStartTime = Date()
        
        // ディレクトリ生成
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = documentsURL.appendingPathComponent("MediaCaptureData/\(sessionID)")
        
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            
            // フレームフォルダのみ作成（音声は単一ファイルにするため）
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("frames"), withIntermediateDirectories: true)
            
            // メタデータ初期化
            frameMetadata = [
                "captureStartTime": Date().timeIntervalSince1970,
                "frameRate": frameRate,
                "quality": quality,
                "frames": []
            ]
            
            captureFolder = folder
            savedFrameCount = 0
            audioBufferSize = 0
            audioBuffer = Data() // 音声バッファをクリア
            
            statusMessage = "キャプチャデータ記録中: \(folder.lastPathComponent)"
            return true
            
        } catch {
            errorMessage = "キャプチャフォルダの作成に失敗: \(error.localizedDescription)"
            return false
        }
    }
    
    // 音声データをバッファに追加（ファイルは作成しない）
    func appendAudioData(_ data: Data) {
        guard isEnabled, captureFolder != nil else { return }
        
        // バッファに追加
        audioBuffer.append(data)
        audioBufferSize = audioBuffer.count
    }
    
    // フレームデータを保存
    func saveFrameData(_ frameData: Data, timestamp: Double, width: Int, height: Int, bytesPerRow: Int, pixelFormat: UInt32) async {
        guard isEnabled, let folder = captureFolder, let startTime = captureStartTime else { return }
        
        let relativeTime = Date().timeIntervalSince(startTime)
        let frameNumber = savedFrameCount + 1
        let framesFolder = folder.appendingPathComponent("frames")
        let frameFile = framesFolder.appendingPathComponent("frame_\(frameNumber)_\(Int(relativeTime * 1000)).raw")
        
        do {
            try frameData.write(to: frameFile)
            
            // フレームメタデータを更新
            let frameInfo: [String: Any] = [
                "frameNumber": frameNumber,
                "timestamp": timestamp,
                "relativeTime": relativeTime,
                "width": width,
                "height": height,
                "bytesPerRow": bytesPerRow,
                "pixelFormat": pixelFormat,
                "filename": frameFile.lastPathComponent
            ]
            
            await MainActor.run {
                // メタデータ配列に追加
                var frames = frameMetadata["frames"] as? [[String: Any]] ?? []
                frames.append(frameInfo)
                frameMetadata["frames"] = frames
                
                savedFrameCount += 1
            }
        } catch {
            await MainActor.run {
                errorMessage = "フレームデータ保存エラー: \(error.localizedDescription)"
            }
        }
    }
    
    // セッション終了時の一括処理
    func finalizeSession(audioSampleRate: Double, channelCount: Int) async -> URL? {
        guard isEnabled, let folder = captureFolder, audioBuffer.count > 0 else { 
            return nil
        }
        
        await MainActor.run {
            isSaving = true
            statusMessage = "キャプチャデータ保存中..."
        }
        
        // 1. 音声データを単一ファイルとして保存
        let audioFile = folder.appendingPathComponent("audio_full.pcm")
        var audioFileURL: URL? = nil
        
        do {
            try audioBuffer.write(to: audioFile)
            audioFileURL = audioFile
            
            // メタデータに音声情報を追加
            frameMetadata["audioInfo"] = [
                "sampleRate": audioSampleRate,
                "channelCount": channelCount,
                "format": "PCM Float32LE",
                "fileSize": audioBuffer.count,
                "filename": audioFile.lastPathComponent
            ]
        } catch {
            await MainActor.run {
                errorMessage = "音声データ保存エラー: \(error.localizedDescription)"
            }
        }
        
        // 2. メタデータJSONを保存
        do {
            // キャプチャ終了情報を追加
            frameMetadata["captureEndTime"] = Date().timeIntervalSince1970
            frameMetadata["totalFrames"] = savedFrameCount
            frameMetadata["totalAudioDataSize"] = audioBuffer.count
            
            let metadataFile = folder.appendingPathComponent("capture_metadata.json")
            let jsonData = try JSONSerialization.data(withJSONObject: frameMetadata, options: .prettyPrinted)
            try jsonData.write(to: metadataFile)
            
            // Finderで表示
            NSWorkspace.shared.selectFile(folder.path, inFileViewerRootedAtPath: "")
            
            await MainActor.run {
                statusMessage = "キャプチャデータ保存完了: フレーム数=\(savedFrameCount), 音声データ=\(audioBuffer.count/1024)KB"
                
                // メモリを解放
                self.audioBuffer = Data()
                self.audioBufferSize = 0
            }
        } catch {
            await MainActor.run {
                errorMessage = "メタデータ保存エラー: \(error.localizedDescription)"
            }
        }
        
        await MainActor.run {
            isSaving = false
        }
        
        return audioFileURL
    }
    
    // 画像ファイルをNSImageとして読み込む
    func loadFrameImage(frameFile: URL, width: Int, height: Int, bytesPerRow: Int) -> NSImage? {
        guard let data = try? Data(contentsOf: frameFile) else {
            return nil
        }
        
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
    
    // 保存されたキャプチャセッションのリストを取得
    func getSavedSessions() -> [(name: String, url: URL)] {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let baseFolder = documentsURL.appendingPathComponent("MediaCaptureData")
        
        // ベースフォルダが存在しない場合は空の配列を返す
        guard FileManager.default.fileExists(atPath: baseFolder.path) else {
            print("DEBUG: MediaCaptureData フォルダが見つかりません: \(baseFolder.path)")
            return []
        }
        
        // フォルダ内容の取得を試みる
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: baseFolder, includingPropertiesForKeys: nil)
            
            // メタデータファイルを持つフォルダのみをフィルタリング
            let validSessions = contents
                .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("capture_metadata.json").path) }
                .map { (name: $0.lastPathComponent, url: $0) }
                .sorted { $0.name > $1.name } // 新しい順に並べ替え
            
            print("DEBUG: 検出されたセッション数: \(validSessions.count)")
            validSessions.forEach { print("  - \($0.name)") }
            
            return validSessions
        } catch {
            print("DEBUG: フォルダ内容の取得に失敗: \(error.localizedDescription)")
            return []
        }
    }
}