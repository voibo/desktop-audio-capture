import Foundation
import CoreGraphics
import AVFoundation
import ScreenCaptureKit


// FrameData 構造体を拡張
public struct FrameData {
    public let data: Data
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let timestamp: Double
    public let pixelFormat: OSType  // ピクセルフォーマットを追加
}

public class ScreenCapture: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private var streamOutput: ScreenCaptureOutput?
    private var running: Bool = false
    private var frameCallback: ((FrameData) -> Void)?
    private var errorCallback: ((String) -> Void)?
    
    // キャプチャの品質設定
    public enum CaptureQuality: Int {
        case high = 0    // 原寸大
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
    
    // キャプチャ対象の種類
    public enum CaptureTarget {
        case screen(displayID: CGDirectDisplayID)  // 特定のスクリーン
        case window(windowID: CGWindowID)          // 特定のウィンドウ
        case application(bundleID: String)         // 特定のアプリケーション
        case entireDisplay                         // 画面全体（デフォルト）
    }
    
    // アプリケーションと関連するウィンドウを表す構造体
    public struct AppWindow: Identifiable, Hashable {
        public let id: CGWindowID
        public let owningApplication: SCRunningApplication?
        public let title: String?
        public let frame: CGRect
        
        public var displayName: String {
            return owningApplication?.applicationName ?? "不明なアプリケーション"
        }
        
        public func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
        
        public static func == (lhs: AppWindow, rhs: AppWindow) -> Bool {
            return lhs.id == rhs.id
        }
    }
    
    // 利用可能なウィンドウの一覧を取得
    class func availableWindows() async throws -> [AppWindow] {
        // 環境変数をチェックしてテスト時はモックを使用
        if ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] == "1" {
            // モックデータを追加
            return [
                AppWindow(
                    id: 1,
                    owningApplication: nil,
                    title: "モックウィンドウ1",
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600)
                ),
                AppWindow(
                    id: 2,
                    owningApplication: nil,
                    title: "モックウィンドウ2",
                    frame: CGRect(x: 100, y: 100, width: 800, height: 600)
                )
            ]
        }
        
        // 実際の実装（既存コード）
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        return content.windows.compactMap { window in
            let title = window.title
            let frame = window.frame
            
            return AppWindow(
                id: window.windowID,
                owningApplication: window.owningApplication,
                title: title,
                frame: frame
            )
        }.sorted { $0.displayName < $1.displayName }
    }
    
    public func startCapture(
        target: CaptureTarget = .entireDisplay,
        frameHandler: @escaping (FrameData) -> Void,
        errorHandler: ((String) -> Void)? = nil,
        framesPerSecond: Double = 1.0, // Double型に変更して小数点以下をサポート
        quality: CaptureQuality = .high
    ) async throws -> Bool {
        if running {
            return false
        }
        
        frameCallback = frameHandler
        errorCallback = errorHandler
        
        // キャプチャターゲットに基づくコンテンツフィルタを作成
        let filter = try await createContentFilter(for: target)
        
        // ストリーム設定の作成
        let configuration = SCStreamConfiguration()
        
        // フレームレートを設定（低フレームレート対応）
        if framesPerSecond >= 1.0 {
            // 1fps以上の通常のフレームレート
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        } else {
            // 1fps未満の低頻度キャプチャ
            let seconds = 1.0 / framesPerSecond
            // 高精度のtimescaleを使用して精度を確保
            configuration.minimumFrameInterval = CMTime(seconds: seconds, preferredTimescale: 600)
        }
        
        // 品質設定（解像度スケーリング）
        if quality != .high {
            // ディスプレイの解像度を取得
            let mainDisplayID = CGMainDisplayID() // if letは不要
            let width = CGDisplayPixelsWide(mainDisplayID) 
            let height = CGDisplayPixelsHigh(mainDisplayID)
            
            // Double型の計算を行い、結果をIntに変換
            let scaleFactor = Double(quality.scale) // Double型に変換
            let scaledWidth = Int(Double(width) * scaleFactor)
            let scaledHeight = Int(Double(height) * scaleFactor)
            
            // サイズ制限を設定
            configuration.width = scaledWidth
            configuration.height = scaledHeight
        }

        // カーソル表示の設定
        configuration.showsCursor = true
        
        // キャプチャ出力を設定
        let output = ScreenCaptureOutput()
        output.frameHandler = { [weak self] (frameData) in
            self?.frameCallback?(frameData)
        }
        output.errorHandler = { [weak self] (error) in
            self?.errorCallback?(error)
        }
        
        streamOutput = output
        
        // ストリームを作成
        stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        
        // 出力設定を追加
        try stream?.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)
        
        // キャプチャ開始
        try await stream?.startCapture()
        
        running = true
        return true
    }
    
    private func createContentFilter(for target: CaptureTarget) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        switch target {
            case .screen(let displayID):
                if let display = content.displays.first(where: { $0.displayID == displayID }) {
                    return SCContentFilter(display: display, excludingWindows: [])
                } else {
                    throw NSError(domain: "ScreenCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "指定されたディスプレイが見つかりません"])
                }
                
            case .window(let windowID):
                if let window = content.windows.first(where: { $0.windowID == windowID }) {
                    return SCContentFilter(desktopIndependentWindow: window)
                } else {
                    throw NSError(domain: "ScreenCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "指定されたウィンドウが見つかりません"])
                }
                
            case .application(let bundleID):
                let appWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID }
                if !appWindows.isEmpty {
                    // アプリケーションの最初のウィンドウを取得
                    if let window = appWindows.first {
                        // 単一ウィンドウフィルタ
                        return SCContentFilter(desktopIndependentWindow: window)
                    } else {
                        throw NSError(domain: "ScreenCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "指定されたアプリケーションのウィンドウが見つかりません"])
                    }
                } else {
                    throw NSError(domain: "ScreenCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "指定されたアプリケーションのウィンドウが見つかりません"])
                }
                
            case .entireDisplay:
                // デフォルトでメインディスプレイを使用
                if let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first {
                    return SCContentFilter(display: mainDisplay, excludingWindows: [])
                } else {
                    throw NSError(domain: "ScreenCapture", code: 4, userInfo: [NSLocalizedDescriptionKey: "利用可能なディスプレイがありません"])
                }
        }
    }
    
    public func stopCapture() async {
        if running {
            try? await stream?.stopCapture()
            stream = nil
            streamOutput = nil
            running = false
        }
    }
    
    public func isCapturing() -> Bool {
        return running
    }
    
    deinit {
        // 弱参照を使ってTaskを作成
        let capturePtr = self.stream
        Task { [weak capturePtr] in
            if let stream = capturePtr {
                try? await stream.stopCapture()
            }
        }
        
        // または非同期処理をdeinitで避け、明示的にリソース解放を推奨
        // deinit内でasyncを使用するのは避ける
        // stream = nil
        // streamOutput = nil
        // running = false
    }
}

// SCStreamOutputプロトコルを実装するクラス
private class ScreenCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    var frameHandler: ((FrameData) -> Void)?
    var errorHandler: ((String) -> Void)?
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        
        let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        
        // YUVフォーマット (420v) とRGBフォーマットで処理を分ける
        let timestamp = CACurrentMediaTime()
        var frameData: FrameData
        
        if pixelFormat == 0x34323076 { // '420v' YUVフォーマット
            // CIImageを利用してYUVからRGBに変換する方法
            CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
            
            // CIImageを作成し、YUVからRGBに変換
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            
            // CIImageからCGImageに変換
            let context = CIContext(options: nil)
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
                print("CIImageからCGImageへの変換に失敗")
                return
            }
            
            // CGImageからビットマップデータを取得
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
                print("CGContextの作成に失敗")
                return
            }
            
            // CGImageを描画
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            
            // ビットマップデータを取得
            guard let data = context.data else {
                print("ビットマップデータの取得に失敗")
                return
            }
            
            // Dataオブジェクトを作成
            let rgbData = Data(bytes: data, count: bytesPerRow * height)
            
            // RGBデータを含むFrameDataを作成
            frameData = FrameData(
                data: rgbData,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                timestamp: timestamp,
                pixelFormat: kCVPixelFormatType_32BGRA // 変換後のフォーマット
            )
            
            print("YUVからRGBに変換: 幅=\(width), 高さ=\(height), bytesPerRow=\(bytesPerRow)")
        } else {
            // 元のコードをそのまま使用（RGBフォーマット用）
            // ピクセルフォーマットの確認とログ出力（デバッグ用）
            let formatName: String
            switch pixelFormat {
            case kCVPixelFormatType_32BGRA:
                formatName = "kCVPixelFormatType_32BGRA"
            case kCVPixelFormatType_32RGBA:
                formatName = "kCVPixelFormatType_32RGBA"
            case kCVPixelFormatType_32ARGB:
                formatName = "kCVPixelFormatType_32ARGB"
            case kCVPixelFormatType_32ABGR:
                formatName = "kCVPixelFormatType_32ABGR"
            default:
                formatName = "Unknown format: \(pixelFormat)"
            }
            print("ピクセルフォーマット: \(formatName)")
              
            // --- デバッグ用 ---
            // CVPixelBufferの詳細情報を出力
            let planeCount = CVPixelBufferGetPlaneCount(imageBuffer)
            print("プレーン数: \(planeCount)")
            
            let pixelFormatType = CVPixelBufferGetPixelFormatType(imageBuffer)
            print("ピクセルフォーマット（16進数）: \(String(format: "0x%08X", pixelFormatType))")
            
            // CVPixelFormatDescription部分を修正
            // 複雑なフォーマット取得処理を削除し、単純な情報表示に変更
            print("フォーマット情報: \(pixelFormatType)")
            
            // 既存のコード...
            CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
            
            let width = CVPixelBufferGetWidth(imageBuffer)
            let height = CVPixelBufferGetHeight(imageBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)

            // --- デバッグ用 ---
            // bytesPerRowが期待値と異なる場合は調整
            let expectedBytesPerRow = width * 4 // 32ビット/ピクセルを想定
            if bytesPerRow != expectedBytesPerRow {
                print("注意: bytesPerRow(\(bytesPerRow))が期待値(\(expectedBytesPerRow))と異なります。")
            }
            
            // アライメント確認
            print("幅: \(width), 高さ: \(height), bytesPerRow: \(bytesPerRow)")
            
            guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else { return }
            
            // フレームデータを構築する前に、必要に応じてデータを再配置
            let data: Data
            if bytesPerRow == width * 4 {
                // 理想的な場合：パディングなし
                data = Data(bytes: baseAddress, count: bytesPerRow * height)
            } else {
                // パディングがある場合：行ごとにコピー
                var newData = Data(capacity: width * height * 4)
                for y in 0..<height {
                    let srcRow = baseAddress.advanced(by: y * bytesPerRow)
                    let actualRowBytes = min(width * 4, bytesPerRow)
                    newData.append(Data(bytes: srcRow, count: actualRowBytes))
                    
                    // 残りのバイトを0で埋める（必要な場合）
                    if actualRowBytes < width * 4 {
                        let padding = [UInt8](repeating: 0, count: width * 4 - actualRowBytes)
                        newData.append(contentsOf: padding)
                    }
                }
                data = newData
                print("データを再アライメント: 元のbytesPerRow=\(bytesPerRow), 新しいbytesPerRow=\(width * 4)")
            }
            let timestamp = CACurrentMediaTime()
            
            // フレームデータを構築
            frameData = FrameData(
                data: data,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                timestamp: timestamp,
                pixelFormat: pixelFormat
            )
        }
        
        // コールバック呼び出し
        DispatchQueue.main.async { [weak self] in
            self?.frameHandler?(frameData)
        }
    }
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let errorMessage = "キャプチャストリームが停止しました: \(error.localizedDescription)"
        errorHandler?(errorMessage)
    }
}
