import SwiftUI
import AVFoundation

struct FramePreviewView: View {
    @ObservedObject var viewModel: FramePreviewViewModel
    
    var body: some View {
        VStack(spacing: 16) {
            // セッション選択
            HStack {
                Text("キャプチャセッション:")
                
                if viewModel.sessions.isEmpty {
                    Text("データがありません").foregroundColor(.secondary)
                    Spacer()
                } else {
                    Picker("", selection: $viewModel.selectedSessionIndex) {
                        ForEach(0..<viewModel.sessions.count, id: \.self) { index in
                            Text(viewModel.sessions[index].name).tag(index)
                        }
                    }
                    .onChange(of: viewModel.selectedSessionIndex) { _ in
                        Task {
                            await viewModel.loadSelectedSession()
                        }
                    }
                }
                
                // ボタンをグループ化
                HStack(spacing: 8) {
                    Button(action: {
                        viewModel.loadSessions()
                    }) {
                        Label("更新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    
                    Button(action: {
                        viewModel.openCaptureFolder()
                    }) {
                        Label("保存先を開く", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.bottom)
            
            if viewModel.isLoading {
                ProgressView("ロード中...")
            } else {
                TabView {
                    // フレームプレビュータブ
                    framePreviewContent
                        .tabItem {
                            Label("フレーム", systemImage: "photo")
                        }
                    
                    // 音声データタブ
                    audioPreviewContent
                        .tabItem {
                            Label("音声データ", systemImage: "waveform")
                        }
                }
            }
        }
        .padding()
        .onAppear {
            viewModel.loadSessions()
        }
    }
    
    // フレームプレビュー内容
    private var framePreviewContent: some View {
        VStack {
            if let metadata = viewModel.sessionMetadata {
                // セッション情報
                GroupBox("セッション情報") {
                    VStack(alignment: .leading) {
                        let captureStartTime = metadata["captureStartTime"] as? Double ?? 0
                        let captureEndTime = metadata["captureEndTime"] as? Double ?? 0
                        let duration = captureEndTime - captureStartTime
                        
                        Text("開始時刻: \(formatTimestamp(captureStartTime))")
                        Text("録画時間: \(String(format: "%.1f秒", duration))")
                        Text("フレーム数: \(viewModel.frames.count)")
                        
                        if let imageFormat = metadata["imageFormat"] as? String {
                            Text("画像フォーマット: \(imageFormat)")
                            
                            if imageFormat == "jpeg", let quality = metadata["imageQuality"] as? Float {
                                Text("JPEG品質: \(String(format: "%.2f", quality))")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom)
                
                // フレーム選択スライダー
                VStack {
                    Text("フレーム: \(viewModel.selectedFrameIndex + 1)/\(viewModel.frames.count)")
                    Slider(
                        value: Binding(
                            get: { Double(viewModel.selectedFrameIndex) },
                            set: { viewModel.selectedFrameIndex = Int($0) }
                        ),
                        in: 0...Double(max(0, viewModel.frames.count - 1)),
                        step: 1
                    )
                }
                .disabled(viewModel.frames.isEmpty)
                
                // 選択したフレームの情報と表示
                if let selectedFrame = viewModel.selectedFrame {
                    GroupBox("フレーム情報") {
                        VStack(alignment: .leading) {
                            Text("相対時間: \(String(format: "%.3f秒", selectedFrame.relativeTime))")
                            Text("サイズ: \(selectedFrame.width) × \(selectedFrame.height)")
                            
                            // 画像フォーマットと品質の情報を追加
                            if let formatInfo = viewModel.selectedFrameFormatInfo {
                                Text("フォーマット: \(formatInfo.format)")
                                if formatInfo.format == "jpeg", let quality = formatInfo.quality {
                                    Text("JPEG品質: \(String(format: "%.2f", quality))")
                                } else if formatInfo.format == "raw" {
                                    Text("フォーマット: Raw (ネイティブピクセルバッファ)")
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.bottom)
                    
                    // 画像表示
                    if let image = viewModel.previewImage {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .border(Color.gray, width: 1)
                    } else {
                        Text("画像の読み込みに失敗しました")
                            .foregroundColor(.red)
                    }
                }
            } else {
                Text("セッションが選択されていないか、メタデータの読み込みに失敗しました")
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // 音声データ再生UI
    private var audioPreviewContent: some View {
        VStack {
            if let metadata = viewModel.sessionMetadata,
               let audioInfo = metadata["audioInfo"] as? [String: Any] {
                
                // 音声ファイル情報
                GroupBox("音声データ情報") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let sampleRate = audioInfo["sampleRate"] as? Double,
                           let channelCount = audioInfo["channelCount"] as? Int,
                           let fileSize = audioInfo["fileSize"] as? Int,
                           let filename = audioInfo["filename"] as? String {
                            
                            Text("ファイル名: \(filename)")
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            
                            Text("フォーマット: \(Int(sampleRate))Hz, \(channelCount)チャンネル, PCM Float32LE")
                            Text("ファイルサイズ: \(fileSize / 1024 / 1024) MB (\(fileSize) バイト)")
                            
                            // 再生コントロール
                            HStack(spacing: 16) {
                                Button(action: {
                                    viewModel.toggleAudioPlayback()
                                }) {
                                    Label(viewModel.isPlaying ? "停止" : "再生", 
                                          systemImage: viewModel.isPlaying ? "stop.fill" : "play.fill")
                                        .frame(width: 100)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(viewModel.isPlaying ? .red : .blue)
                                
                                if viewModel.isPlaying {
                                    Text("再生中: \(String(format: "%.1f", viewModel.playbackPosition))秒")
                                        .foregroundColor(.blue)
                                }
                            }
                            .padding(.vertical, 8)
                            
                            // 再生位置スライダー
                            if viewModel.audioDuration > 0 {
                                VStack(spacing: 4) {
                                    Slider(value: $viewModel.playbackPosition, 
                                           in: 0...viewModel.audioDuration,
                                           onEditingChanged: { editing in
                                        if !editing {
                                            viewModel.seekToPosition(viewModel.playbackPosition)
                                        }
                                    })
                                    
                                    HStack {
                                        Text("0:00")
                                        Spacer()
                                        Text(formatDuration(viewModel.audioDuration))
                                    }
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                }
                            }
                            
                            // ユーティリティボタン
                            HStack {
                                Button(action: {
                                    viewModel.copyFFPlayCommand()
                                }) {
                                    Label("ffplayコマンドをコピー", systemImage: "doc.on.clipboard")
                                }
                                .buttonStyle(.bordered)
                                
                                Button(action: {
                                    viewModel.convertToMono()
                                }) {
                                    Label("モノラルに変換", systemImage: "waveform")
                                }
                                .buttonStyle(.bordered)
                                .disabled(viewModel.isConverting)
                                
                                Button(action: {
                                    viewModel.openInFinder()
                                }) {
                                    Label("Finderで表示", systemImage: "folder")
                                }
                                .buttonStyle(.bordered)
                            }
                            
                            if viewModel.isConverting {
                                HStack {
                                    ProgressView()
                                    Text("変換中...")
                                }
                                .padding(.top, 4)
                            }
                            
                            if let message = viewModel.statusMessage {
                                Text(message)
                                    .foregroundColor(viewModel.isStatusError ? .red : .green)
                                    .padding(.top, 4)
                            }
                        } else {
                            Text("音声データが見つかりません")
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                // 波形表示（あれば）
                if !viewModel.audioWaveform.isEmpty {
                    GroupBox("波形") {
                        AudioWaveformView(levels: viewModel.audioWaveform, color: .blue)
                            .frame(height: 100)
                    }
                }
                
            } else {
                Text("音声データが含まれていないセッションか、メタデータが読み込めません")
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // タイムスタンプをフォーマット
    private func formatTimestamp(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
    
    // 時間のフォーマット
    private func formatDuration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return "\(minutes):\(String(format: "%02d", remainingSeconds))"
    }
}
