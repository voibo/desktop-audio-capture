import SwiftUI
import AVFoundation
import ScreenCaptureKit

struct ContentView: View {
    @State private var screenCapture = ScreenCapture()
    @State private var isCapturing = false
    @State private var latestImage: NSImage?
    @State private var frameCount = 0
    
    var body: some View {
        VStack {
            if let image = latestImage {
                Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit) // アスペクト比を維持
                        .frame(maxWidth: 800, maxHeight: 600)
                        .border(Color.gray, width: 1) // 境界を表示して確認しやすく
            } else {
                Text("キャプチャ待機中...")
                    .frame(width: 800, height: 600)
                    .background(Color.gray.opacity(0.2))
            }
            
            Text("フレーム数: \(frameCount)")
            
            Button(isCapturing ? "停止" : "開始") {
                if isCapturing {
                    Task {
                        await screenCapture.stopCapture()
                        isCapturing = false
                    }
                } else {
                    Task {
                        do {
                            let success = try await screenCapture.startCapture(
                                target: .entireDisplay,
                                frameHandler: { frameData in
                                    convertFrameToImage(frameData)
                                    frameCount += 1
                                },
                                errorHandler: { error in
                                    print("エラー: \(error)")
                                },
                                framesPerSecond: 10,
                                quality: .medium
                            )
                            
                            if success {
                                isCapturing = true
                                print("キャプチャ開始成功")
                            } else {
                                print("キャプチャは既に実行中")
                            }
                        } catch {
                            print("キャプチャ開始エラー: \(error)")
                        }
                    }
                }
            }
            .padding()
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
    
    func convertFrameToImage(_ frameData: FrameData) {
        let width = frameData.width
        let height = frameData.height
        let bytesPerRow = frameData.bytesPerRow
        let pixelFormat = frameData.pixelFormat
        
        print("変換開始: フォーマット=\(pixelFormat), 幅=\(width), 高さ=\(height), 行バイト数=\(bytesPerRow)")
        
        // カラースペースとビットマップ情報
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        // BGRAフォーマット (変換後のデータ用)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        
        guard let provider = CGDataProvider(data: frameData.data as CFData),
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
            print("画像変換に失敗: width=\(width), height=\(height), bytesPerRow=\(bytesPerRow)")
            return
        }
        
        // 正しいサイズでNSImageを作成
        let image = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        
        DispatchQueue.main.async {
            self.latestImage = image
        }
    }
}
