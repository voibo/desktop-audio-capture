//
//  ContentView.swift
//  MediaCaptureTest
//
//  Created by Nobuhiro Hayashi on 2025/02/28.
//

import SwiftUI
import AVFoundation
import ScreenCaptureKit

struct ContentView: View {
    @StateObject private var viewModel = MediaCaptureViewModel()
    
    var body: some View {
        NavigationView {
            // サイドバー（設定エリア）
            SettingsView(viewModel: viewModel)
                .frame(minWidth: 300)
                .listStyle(.sidebar)
            
            // プレビューエリア
            PreviewView(viewModel: viewModel)
                .padding()
                .frame(minWidth: 500, minHeight: 400)
        }
        .navigationTitle("MediaCapture テスト")
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            Task {
                await viewModel.loadAvailableTargets()
            }
        }
    }
}

// 設定パネル用のビュー
struct SettingsView: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    
    var body: some View {
        List {
            // キャプチャ対象選択セクション
            TargetSelectionSection(viewModel: viewModel)
            
            // キャプチャ設定セクション
            CaptureSettingsSection(viewModel: viewModel)
            
            // 統計情報セクション
            StatsSection(viewModel: viewModel)
            
            // キャプチャ制御セクション
            ControlSection(viewModel: viewModel)
        }
    }
}

// キャプチャ対象選択セクション
struct TargetSelectionSection: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    
    var body: some View {
        Section(header: Text("キャプチャ対象")) {
            if viewModel.isLoading {
                ProgressView("読み込み中...")
            } else if viewModel.availableTargets.isEmpty {
                Text("利用可能なキャプチャ対象がありません")
                    .foregroundStyle(.secondary)
            } else {
                TextField("検索", text: $viewModel.searchText)
                
                Picker("キャプチャ対象", selection: $viewModel.selectedTargetIndex) {
                    ForEach(Array(viewModel.filteredTargets.enumerated()), id: \.offset) { index, target in
                        Text(targetTitle(target)).tag(index)
                    }
                }
                .pickerStyle(.menu)
            }
            
            Button("キャプチャ対象を更新") {
                Task {
                    await viewModel.loadAvailableTargets()
                }
            }
        }
    }
    
    private func targetTitle(_ target: MediaCaptureTarget) -> String {
        if target.isWindow {
            if let appName = target.applicationName, let title = target.title {
                return "\(appName): \(title)"
            } else if let title = target.title {
                return title
            } else {
                return "ウィンドウ \(target.windowID)"
            }
        } else if target.isDisplay {
            return target.title ?? "ディスプレイ \(target.displayID)"
        } else {
            return "不明なターゲット"
        }
    }
}

// キャプチャ設定セクション
struct CaptureSettingsSection: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    
    var body: some View {
        Section(header: Text("キャプチャ設定")) {
            Toggle("音声のみ（フレームレート0）", isOn: $viewModel.audioOnly)
            
            if !viewModel.audioOnly {
                Picker("画質", selection: $viewModel.selectedQuality) {
                    Text("高").tag(0)
                    Text("中").tag(1)
                    Text("低").tag(2)
                }
                .pickerStyle(.segmented)
                
                // フレームレートモードの選択
                Picker("フレームレートモード", selection: $viewModel.frameRateMode) {
                    Text("標準").tag(0)
                    Text("低速").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 4)
                
                VStack {
                    HStack {
                        // モードに応じた表示を変更
                        if viewModel.frameRateMode == 0 {
                            Text("フレームレート: \(Int(viewModel.frameRate)) fps")
                        } else {
                            // 低速モードでは「X秒ごと」と表示
                            let interval = 1.0 / viewModel.lowFrameRate
                            Text("間隔: \(String(format: "%.1f", interval)) 秒ごと")
                        }
                        Spacer()
                    }
                    
                    if viewModel.frameRateMode == 0 {
                        // 標準モード: 1〜60fps
                        Slider(value: $viewModel.frameRate, in: 1...60, step: 1)
                    } else {
                        // 低速モード: 0.1〜0.9fps (10秒〜1.1秒ごと)
                        Slider(value: $viewModel.lowFrameRate, in: 0.1...0.9, step: 0.1)
                    }
                }
                
                // プリセット選択（低速モード用）
                if viewModel.frameRateMode == 1 {
                    HStack(spacing: 12) {
                        Button("1秒ごと") { viewModel.lowFrameRate = 0.9 }
                        Button("2秒ごと") { viewModel.lowFrameRate = 0.5 }
                        Button("3秒ごと") { viewModel.lowFrameRate = 0.33 }
                        Button("5秒ごと") { viewModel.lowFrameRate = 0.2 }
                        Button("10秒ごと") { viewModel.lowFrameRate = 0.1 }
                    }
                    .buttonStyle(.bordered)
                    .font(.footnote)
                }
            }
        }
    }
}

// 統計情報セクション
struct StatsSection: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    
    var body: some View {
        Section(header: Text("統計情報")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("音声レベル")
                
                // 音声レベルメーター
                AudioLevelMeter(level: viewModel.audioLevel)
                    .frame(height: 20)
                
                // 音声波形表示を追加
                Text("音声波形（直近の変化）")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                
                AudioWaveformView(
                    levels: viewModel.audioLevelHistory,
                    color: waveformColor(level: viewModel.audioLevel)
                )
                .frame(height: 80)
                .padding(.bottom, 8)
            }
            
            HStack {
                Text("受信フレーム数:")
                Spacer()
                Text("\(viewModel.frameCount)")
            }
            
            HStack {
                Text("FPS:")
                Spacer()
                Text(String(format: "%.1f", viewModel.currentFPS))
            }
            
            HStack {
                Text("映像サイズ:")
                Spacer()
                Text(viewModel.imageSize)
            }
            
            HStack {
                Text("音声サンプルレート:")
                Spacer()
                Text("\(Int(viewModel.audioSampleRate)) Hz")
            }
            
            HStack {
                Text("遅延:")
                Spacer()
                Text(String(format: "%.1f ms", viewModel.captureLatency))
            }
        }
    }
    
    // 音声レベルに応じて波形の色を変更
    private func waveformColor(level: Float) -> Color {
        switch level {
        case 0..<0.5:
            return .green
        case 0.5..<0.8:
            return .yellow
        default:
            return .red
        }
    }
}

// キャプチャ制御セクション
struct ControlSection: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    
    var body: some View {
        Section {
            // キャプチャコントロール
            HStack {
                Spacer()
                Button(viewModel.isCapturing ? "キャプチャ停止" : "キャプチャ開始") {
                    Task {
                        if viewModel.isCapturing {
                            await viewModel.stopCapture()
                        } else {
                            await viewModel.startCapture()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.isCapturing ? .red : .blue)
                .disabled(viewModel.availableTargets.isEmpty || viewModel.isLoading)
                Spacer()
            }
            
            // 音声記録状態表示
            if viewModel.isCapturing && viewModel.isAudioRecording {
                Divider()
                
                // 録音状態表示
                HStack {
                    Label(
                        "音声データ記録中: \(String(format: "%.1f秒", viewModel.audioRecordingTime))", 
                        systemImage: "waveform"
                    )
                    .foregroundColor(.red)
                    
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            
            // 保存した音声ファイルの情報（キャプチャ中かどうかに関わらず表示）
            if let audioFileURL = viewModel.audioFileURL {
                Divider()
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("保存済み生データ (PCM):")
                        .font(.headline)
                        .padding(.top, 4)
                    
                    Text(audioFileURL.lastPathComponent)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Text(viewModel.audioFormatDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                    
                    HStack {
                        // ファイル保存場所を表示
                        Button(action: {
                            NSWorkspace.shared.selectFile(audioFileURL.path, inFileViewerRootedAtPath: "")
                        }) {
                            Label("Finderで表示", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        
                        // コマンドをクリップボードにコピー
                        Button(action: {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(viewModel.getFFplayCommand(), forType: .string)
                            viewModel.errorMessage = "ffplayコマンドをコピーしました"
                        }) {
                            Label("ffplayコマンド", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                        
                        // モノラル変換ボタンを追加
                        Button("モノラルに変換してDL") {
                            viewModel.saveAudioToMonoFile()
                        }
                        .help("ステレオ音声をモノラルに変換して保存します")
                    }
                }
                .padding(.vertical, 4)
            }
            
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.footnote)
            }
        }
    }
}

// プレビューエリアのビュー
struct PreviewView: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    
    var body: some View {
        if viewModel.isCapturing {
            if let nsImage = viewModel.previewImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(.default, value: nsImage)
            } else if viewModel.audioOnly {
                AudioOnlyView(level: viewModel.audioLevel)
            }
        } else {
            WaitingView()
        }
    }
}

// 音声のみモード用ビュー
struct AudioOnlyView: View {
    var level: Float
    
    var body: some View {
        VStack {
            Image(systemName: "waveform")
                .font(.system(size: 80))
                .foregroundColor(.green.opacity(0.6 + Double(level) * 0.4))  // Float から Double に明示的に変換
                .animation(.easeInOut(duration: 0.1), value: level)
            Text("音声キャプチャ中")
                .font(.title2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.05))
    }
}

// 待機中ビュー
struct WaitingView: View {
    var body: some View {
        VStack {
            Image(systemName: "display")
                .font(.system(size: 80))
                .foregroundColor(.gray)
            Text("キャプチャ待機中...")
                .font(.title2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.05))
    }
}

// オーディオレベルを視覚化するビュー
struct AudioLevelMeter: View {
    var level: Float
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .opacity(0.2)
                    .foregroundColor(.gray)
                
                Rectangle()
                    .frame(width: CGFloat(self.level) * geometry.size.width, height: geometry.size.height)
                    .foregroundColor(levelColor)
            }
            .cornerRadius(5)
        }
    }
    
    var levelColor: Color {
        if level < 0.5 {
            return .green
        } else if level < 0.8 {
            return .yellow
        } else {
            return .red
        }
    }
}

// 音声波形を表示するビュー
struct AudioWaveformView: View {
    var levels: [Float]
    var color: Color = .green
    
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                let stepX = width / CGFloat(levels.count - 1)
                
                // 波形の中心線
                let centerY = height / 2
                
                // 最初のポイントを設定
                path.move(to: CGPoint(x: 0, y: centerY - CGFloat(levels[0]) * centerY))
                
                // 残りのポイントを追加
                for i in 1..<levels.count {
                    let x = CGFloat(i) * stepX
                    let y = centerY - CGFloat(levels[i]) * centerY
                    
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                
                // 波形を閉じる（下部）
                path.addLine(to: CGPoint(x: width, y: centerY + CGFloat(levels[levels.count - 1]) * centerY))
                
                // 逆順に下部の点を追加
                for i in (0..<levels.count-1).reversed() {
                    let x = CGFloat(i) * stepX
                    let y = centerY + CGFloat(levels[i]) * centerY
                    
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                
                // パスを閉じる
                path.closeSubpath()
            }
            .fill(
                LinearGradient(
                    gradient: Gradient(colors: [color.opacity(0.5), color.opacity(0.2)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            
            // 線（トップエッジ）
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                let stepX = width / CGFloat(levels.count - 1)
                
                // 波形の中心線
                let centerY = height / 2
                
                // 最初のポイントを設定
                path.move(to: CGPoint(x: 0, y: centerY - CGFloat(levels[0]) * centerY))
                
                // 残りのポイントを追加
                for i in 1..<levels.count {
                    let x = CGFloat(i) * stepX
                    let y = centerY - CGFloat(levels[i]) * centerY
                    
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(color, lineWidth: 1.5)
        }
    }
}

#Preview {
    ContentView()
}
