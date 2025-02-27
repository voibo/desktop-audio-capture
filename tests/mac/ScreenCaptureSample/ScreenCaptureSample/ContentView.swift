import SwiftUI
import AVFoundation
import ScreenCaptureKit

struct ContentView: View {
    // 既存の変数を維持
    @State private var screenCapture = ScreenCapture()
    // 追加：タブ選択状態
    @State private var selectedTab = 0 // 0: 画面キャプチャ、1: 音声キャプチャ
    
    // 音声キャプチャ関連
    @State private var audioCapture = AudioCapture()
    @State private var isAudioCapturing = false
    @State private var audioBuffer: AVAudioPCMBuffer?
    @State private var audioLevels: [Float] = Array(repeating: 0, count: 10)
    @State private var audioSampleRate: Double = 0
    @State private var audioChannels: Int = 0
    @State private var audioError: String? = nil
    
    // 共通のキャプチャターゲット
    @State private var selectedTargetType = 0 // 0: 全画面、1:ディスプレイ、2:ウィンドウ、3:アプリ
    @State private var selectedDisplayID: CGDirectDisplayID?
    @State private var selectedWindowID: CGWindowID?
    @State private var selectedBundleID: String = ""
    
    // 既存の状態変数
    @State private var isCapturing = false
    @State private var latestImage: NSImage?
    @State private var frameCount = 0
    @State private var lastFrameTimestamp: TimeInterval = 0
    @State private var fpsCounter: Double = 0
    
    // キャプチャ設定
    @State private var selectedCaptureMode = 0
    @State private var selectedQuality = 1
    @State private var frameRate = 1.0 // デフォルト値を変更
    @State private var showCursor = true
    @State private var useIntervalMode = false // 間隔モード切替
    @State private var captureInterval = 1.0 // キャプチャ間隔（秒）
    
    // ディスプレイ、ウィンドウ、アプリのリスト
    @State private var displays: [(id: CGDirectDisplayID, name: String)] = []
    @State private var windows: [ScreenCapture.AppWindow] = []
    @State private var selectedDisplayIndex = 0
    @State private var selectedWindowIndex = 0
    @State private var bundleID = ""
    
    // 統計情報
    @State private var captureLatency: Double = 0
    @State private var imageSize: String = "-"
    @State private var pixelFormat: String = "-"
    @State private var error: String? = nil
    
    // タイマー
    let fpsTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // 既存の画面キャプチャビュー
            screenCaptureView
                .tabItem {
                    Label("画面キャプチャ", systemImage: "display")
                }
                .tag(0)
            
            // 新しい音声キャプチャビュー
            audioCaptureView
                .tabItem {
                    Label("音声キャプチャ", systemImage: "mic")
                }
                .tag(1)
        }
    }
    
    // 画面キャプチャタブのUI
    var screenCaptureView: some View {
        NavigationView {
            List {
                // キャプチャ対象の選択
                Section(header: Text("キャプチャ対象")) {
                    Picker("キャプチャモード", selection: $selectedCaptureMode) {
                        Text("全画面").tag(0)
                        Text("ディスプレイ").tag(1)
                        Text("ウィンドウ").tag(2)
                        Text("アプリケーション").tag(3)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .onChange(of: selectedCaptureMode) {
                        loadCaptureTargets()
                    }
                    
                    // 選択したモードに応じたオプション
                    switch selectedCaptureMode {
                    case 1: // ディスプレイ
                        Picker("ディスプレイ", selection: $selectedDisplayIndex) {
                            ForEach(0..<displays.count, id: \.self) { index in
                                Text(displays[index].name).tag(index)
                            }
                        }
                        
                    case 2: // ウィンドウ
                        Picker("ウィンドウ", selection: $selectedWindowIndex) {
                            ForEach(0..<windows.count, id: \.self) { index in
                                Text(windows[index].title ?? "不明なウィンドウ").tag(index)
                            }
                        }
                        
                    case 3: // アプリケーション
                        TextField("バンドルID (例: com.apple.finder)", text: $bundleID)
                        
                    default:
                        EmptyView()
                    }
                }
                
                // 品質設定
                Section(header: Text("品質設定")) {
                    Picker("品質", selection: $selectedQuality) {
                        Text("高 (100%)").tag(0)
                        Text("中 (75%)").tag(1)
                        Text("低 (50%)").tag(2)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    
                    Toggle("カーソルを表示", isOn: $showCursor)
                }
                
                // 頻度設定セクション（修正）
                Section(header: Text("キャプチャ頻度")) {
                    Toggle("低頻度キャプチャモード", isOn: $useIntervalMode)
                        .onChange(of: useIntervalMode) {
                            // モード切替時に値を更新
                            if useIntervalMode {
                                // 低頻度モードの初期値
                                captureInterval = 1.0
                                frameRate = 1.0 / captureInterval
                            } else {
                                // 通常モードの初期値
                                frameRate = 1.0
                            }
                        }
                    
                    if useIntervalMode {
                        // 間隔ベースのスライダー（低頻度用）
                        VStack {
                            HStack {
                                Text("キャプチャ間隔: \(String(format: "%.1f", captureInterval)) 秒")
                                Spacer()
                            }
                            Slider(value: $captureInterval, in: 0.5...60.0, step: 0.5)
                                .onChange(of: captureInterval) {
                                    // 間隔からフレームレートを計算
                                    frameRate = 1.0 / captureInterval
                                }
                        }
                        Text("（約\(String(format: "%.3f", frameRate)) fps）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        // 従来のフレームレートスライダー
                        VStack {
                            HStack {
                                Text("フレームレート: \(String(format: "%.1f", frameRate)) fps")
                                Spacer()
                            }
                            Slider(value: $frameRate, in: 1.0...30.0, step: 1.0)
                        }
                    }
                }
                
                // 統計情報
                Section(header: Text("統計情報")) {
                    HStack {
                        Text("フレーム数:")
                        Spacer()
                        Text("\(frameCount)")
                    }
                    
                    HStack {
                        Text("FPS:")
                        Spacer()
                        Text(String(format: "%.1f", fpsCounter))
                    }
                    
                    HStack {
                        Text("遅延:")
                        Spacer()
                        Text(String(format: "%.1f ms", captureLatency))
                    }
                    
                    HStack {
                        Text("サイズ:")
                        Spacer()
                        Text(imageSize)
                    }
                    
                    HStack {
                        Text("フォーマット:")
                        Spacer()
                        Text(pixelFormat)
                    }
                    
                    HStack {
                        Text("キャプチャ間隔:")
                        Spacer()
                        Text(frameRate < 1.0 ? "\(String(format: "%.1f", 1.0 / frameRate)) 秒" : "-")
                    }
                    
                    if let error = error {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
                
                // キャプチャ開始/停止ボタン
                Section {
                    HStack {
                        Spacer()
                        Button(isCapturing ? "キャプチャ停止" : "キャプチャ開始") {
                            if isCapturing {
                                stopCapture()
                            } else {
                                startCapture()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                }
                
                // 画面更新ボタン
                Section {
                    HStack {
                        Spacer()
                        Button("キャプチャ対象を更新") {
                            loadCaptureTargets()
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                    }
                }
            }
            .frame(minWidth: 300)
            .listStyle(SidebarListStyle())
            .onAppear {
                loadCaptureTargets()
            }
            .onReceive(fpsTimer) { _ in
                if isCapturing {
                    self.updateFPS()
                }
            }
            
            // プレビューエリア
            VStack {
                if let image = latestImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .border(Color.gray, width: 1)
                } else {
                    VStack {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        Text("キャプチャ待機中...")
                            .font(.title2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.05))
                }
                
                Text("最新フレーム: \(formatTimestamp(lastFrameTimestamp))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(minWidth: 600)
            .padding()
        }
        .frame(minWidth: 900, minHeight: 600)
        .navigationTitle("スクリーンキャプチャテスト")
    }
    
    // 音声キャプチャタブのUI
    var audioCaptureView: some View {
        NavigationView {
            List {
                // キャプチャ対象セクション
                Section(header: Text("キャプチャ対象")) {
                    // 既存のキャプチャ対象選択UIを再利用
                    Picker("キャプチャモード", selection: $selectedTargetType) {
                        Text("全画面").tag(0)
                        Text("ディスプレイ").tag(1)
                        Text("ウィンドウ").tag(2)
                        Text("アプリケーション").tag(3)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .onChange(of: selectedTargetType) {
                        loadCaptureTargets()
                    }
                    
                    // 選択したモードに応じたオプション
                    // (既存と同じ表示コード)
                }
                
                // 音声キャプチャ設定
                Section(header: Text("音声設定")) {
                    Toggle("システム音声をキャプチャ", isOn: .constant(true))
                    Toggle("マイク入力をキャプチャ", isOn: .constant(false))
                    
                    HStack {
                        Text("サンプリングレート:")
                        Spacer()
                        Text("\(Int(audioSampleRate)) Hz")
                    }
                    
                    HStack {
                        Text("チャンネル数:")
                        Spacer()
                        Text("\(audioChannels)")
                    }
                }
                
                // 音声レベルメーター表示
                Section(header: Text("音声レベル")) {
                    HStack(spacing: 2) {
                        ForEach(0..<audioLevels.count, id: \.self) { i in
                            Rectangle()
                                .fill(levelColor(level: audioLevels[i]))
                                .frame(width: 20, height: CGFloat(audioLevels[i] * 100))
                        }
                    }
                    .frame(height: 100, alignment: .bottom)
                    .animation(.easeOut, value: audioLevels)
                }
                
                // エラー表示
                if let error = audioError {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
                
                // キャプチャ開始/停止ボタン
                Section {
                    HStack {
                        Spacer()
                        Button(isAudioCapturing ? "音声キャプチャ停止" : "音声キャプチャ開始") {
                            if isAudioCapturing {
                                stopAudioCapture()
                            } else {
                                startAudioCapture()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                }
            }
            .frame(minWidth: 300)
            .listStyle(SidebarListStyle())
            
            // 右側の音声波形表示
            VStack {
                if isAudioCapturing {
                    // 波形表示コンポーネント
                    AudioWaveformView(audioLevels: audioLevels)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack {
                        Image(systemName: "waveform")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        Text("音声キャプチャ待機中...")
                            .font(.title2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.05))
                }
                
                if isAudioCapturing {
                    Text("サンプリングレート: \(Int(audioSampleRate)) Hz、チャンネル数: \(audioChannels)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(minWidth: 600)
            .padding()
        }
    }
    
    // キャプチャ対象の読み込み
    private func loadCaptureTargets() {
        // ディスプレイ情報の取得
        displays = []
        for displayID in (0..<32).compactMap({ CGMainDisplayID() + UInt32($0) }) {
            if CGDisplayIsActive(displayID) != 0 {
                let name = "ディスプレイ \(displays.count + 1) (ID: \(displayID))"
                displays.append((id: displayID, name: name))
            }
        }
        
        // ウィンドウ情報の取得
        Task {
            do {
                self.windows = try await ScreenCapture.availableWindows()
                if self.windows.isEmpty {
                    self.error = "利用可能なウィンドウがありません"
                } else {
                    self.error = nil
                }
            } catch {
                self.error = "ウィンドウ情報の取得に失敗: \(error.localizedDescription)"
            }
        }
    }
    
    // キャプチャ開始
    private func startCapture() {
        // キャプチャ対象の選択
        let target: ScreenCapture.CaptureTarget
        
        switch selectedCaptureMode {
        case 1:
            guard !displays.isEmpty else {
                self.error = "ディスプレイがありません"
                return
            }
            target = .screen(displayID: displays[selectedDisplayIndex].id)
        case 2:
            guard !windows.isEmpty else {
                self.error = "ウィンドウがありません"
                return
            }
            target = .window(windowID: windows[selectedWindowIndex].id)
        case 3:
            guard !bundleID.isEmpty else {
                self.error = "バンドルIDを入力してください"
                return
            }
            target = .application(bundleID: bundleID)
        default:
            target = .entireDisplay
        }
        
        // 品質設定
        let quality: ScreenCapture.CaptureQuality
        switch selectedQuality {
        case 0: quality = .high
        case 2: quality = .low
        default: quality = .medium
        }
        
        // キャプチャ開始
        Task {
            do {
                // フレームカウンターのリセット
                frameCount = 0
                fpsCounter = 0
                
                let startTime = Date()
                let success = try await screenCapture.startCapture(
                    target: target,
                    frameHandler: { frameData in
                        self.processFrame(frameData)
                    },
                    errorHandler: { error in
                        self.error = error
                    },
                    framesPerSecond: frameRate, // 小数点以下のフレームレートも渡せるように
                    quality: quality
                )
                
                if success {
                    isCapturing = true
                    self.error = nil
                    print("キャプチャ開始: \(Date().timeIntervalSince(startTime)) 秒")
                } else {
                    self.error = "キャプチャは既に実行中です"
                }
            } catch {
                self.error = "キャプチャ開始エラー: \(error.localizedDescription)"
            }
        }
    }
    
    // キャプチャ停止
    private func stopCapture() {
        Task {
            await screenCapture.stopCapture()
            DispatchQueue.main.async {
                self.isCapturing = false
            }
        }
    }
    
    // フレーム処理
    private func processFrame(_ frameData: FrameData) {
        let now = Date().timeIntervalSince1970
        captureLatency = (now - frameData.timestamp) * 1000 // ミリ秒単位
        lastFrameTimestamp = frameData.timestamp
        
        imageSize = "\(frameData.width) × \(frameData.height)"
        pixelFormat = formatPixelType(frameData.pixelFormat)
        
        convertFrameToImage(frameData)
        frameCount += 1
    }
    
    // FPS更新
    private func updateFPS() {
        let oldCount = frameCount - Int(fpsCounter)
        fpsCounter = Double(oldCount)
    }
    
    // 画像変換
    private func convertFrameToImage(_ frameData: FrameData) {
        let width = frameData.width
        let height = frameData.height
        let bytesPerRow = frameData.bytesPerRow
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
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
        
        let image = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        
        DispatchQueue.main.async {
            self.latestImage = image
        }
    }
    
    // 音声キャプチャ開始
    private func startAudioCapture() {
        // キャプチャ対象の構成
        let sharedTarget = createSharedCaptureTarget()
        
        // キャプチャ設定
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        
        // キャプチャ開始
        Task {
            do {
                // 既存のaudioCapture.startCaptureを使用
                for try await pcmBuffer in audioCapture.startCapture(
                    target: sharedTarget,
                    configuration: configuration
                ) {
                    // PCMバッファからレベル計算
                    updateAudioLevels(pcmBuffer)
                    
                    // オーディオ情報の更新
                    DispatchQueue.main.async {
                        self.audioBuffer = pcmBuffer
                        self.audioSampleRate = pcmBuffer.format.sampleRate
                        self.audioChannels = Int(pcmBuffer.format.channelCount)
                        self.isAudioCapturing = true
                        self.audioError = nil
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.audioError = "音声キャプチャエラー: \(error.localizedDescription)"
                    self.isAudioCapturing = false
                }
            }
        }
    }
    
    // 音声キャプチャ停止
    private func stopAudioCapture() {
        Task {
            await audioCapture.stopCapture()
            DispatchQueue.main.async {
                self.isAudioCapturing = false
            }
        }
    }
    
    // 共通のキャプチャターゲット作成
    private func createSharedCaptureTarget() -> SharedCaptureTarget {
        switch selectedTargetType {
        case 1: // ディスプレイ
            return SharedCaptureTarget(
                displayID: selectedDisplayID ?? CGMainDisplayID()
            )
        case 2: // ウィンドウ
            return SharedCaptureTarget(
                windowID: selectedWindowID ?? 0
            )
        case 3: // アプリケーション
            return SharedCaptureTarget(
                bundleID: selectedBundleID.isEmpty ? nil : selectedBundleID
            )
        default: // 全画面
            return SharedCaptureTarget(displayID: CGMainDisplayID())
        }
    }
    
    // オーディオレベルの更新
    private func updateAudioLevels(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var levels = Array(repeating: Float(0), count: audioLevels.count)
        
        // 簡易的なレベル計算 (実際はもっと洗練された計算が必要)
        for segment in 0..<audioLevels.count {
            let segmentSize = frameLength / audioLevels.count
            let startFrame = segment * segmentSize
            let endFrame = min(startFrame + segmentSize, frameLength)
            
            var sum: Float = 0
            for channel in 0..<channelCount {
                for frame in startFrame..<endFrame {
                    sum += abs(channelData[channel][frame])
                }
            }
            
            let average = sum / Float(endFrame - startFrame) / Float(channelCount)
            levels[segment] = min(average * 5, 1.0) // スケーリング
        }
        
        DispatchQueue.main.async {
            self.audioLevels = levels
        }
    }
    
    // フォーマット関連のヘルパー関数
    private func formatTimestamp(_ timestamp: TimeInterval) -> String {
        guard timestamp > 0 else { return "-" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
    
    private func formatPixelType(_ type: OSType) -> String {
        switch type {
        case kCVPixelFormatType_32BGRA: return "BGRA 8bit"
        case kCVPixelFormatType_32RGBA: return "RGBA 8bit"
        case kCVPixelFormatType_32ARGB: return "ARGB 8bit"
        case kCVPixelFormatType_32ABGR: return "ABGR 8bit"
        case 0x34323076: return "YUV 4:2:0"
        default: return String(format: "0x%08X", type)
        }
    }
    
    // レベルに応じた色を返す
    private func levelColor(level: Float) -> Color {
        if level > 0.8 { return .red }
        if level > 0.6 { return .orange }
        if level > 0.4 { return .yellow }
        return .green
    }
}

// 波形表示用のカスタムビュー
struct AudioWaveformView: View {
    var audioLevels: [Float]
    
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                let segmentWidth = width / CGFloat(audioLevels.count)
                
                // 中央線
                path.move(to: CGPoint(x: 0, y: height/2))
                path.addLine(to: CGPoint(x: width, y: height/2))
                
                // 波形描画
                for (index, level) in audioLevels.enumerated() {
                    let x = CGFloat(index) * segmentWidth
                    let topY = height/2 - CGFloat(level) * height/2
                    let bottomY = height/2 + CGFloat(level) * height/2
                    
                    path.move(to: CGPoint(x: x, y: topY))
                    path.addLine(to: CGPoint(x: x, y: bottomY))
                }
            }
            .stroke(Color.blue, lineWidth: 2)
        }
    }
}
