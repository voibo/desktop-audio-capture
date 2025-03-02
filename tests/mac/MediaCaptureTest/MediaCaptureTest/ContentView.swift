import SwiftUI
import AVFoundation
import ScreenCaptureKit

// タブ間ナビゲーション用モデル
class NavigationViewModel: ObservableObject {
    @Published var selectedTab: Int = 0
}

// タブ間でデータを共有するためのNotification名を定義
extension Notification.Name {
    static let captureCompleted = Notification.Name("captureCompleted")
}

struct ContentView: View {
    @StateObject var viewModel = MediaCaptureViewModel()
    @StateObject var navigationModel = NavigationViewModel()
    @StateObject var previewViewModel = FramePreviewViewModel() // 共有インスタンスに変更
    
    var body: some View {
        NavigationView {
            TabView(selection: $navigationModel.selectedTab) {
                // 通常のキャプチャ画面
                NavigationView {
                    SettingsView(viewModel: viewModel)
                        .frame(minWidth: 300)
                        .listStyle(.sidebar)
                    
                    VStack(spacing: 0) {
                        // Top area: Current preview
                        PreviewView(viewModel: viewModel)
                            .padding()
                            .frame(height: 400)
                    }
                    .frame(minWidth: 500)
                }
                .navigationTitle("MediaCapture")
                .tabItem {
                    Label("キャプチャ", systemImage: "video")
                }
                .tag(0)
                
                
                // フレームプレビュータブ - 共有インスタンスを使用
                FramePreviewView(viewModel: previewViewModel)
                    .tabItem {
                        Label("プレビュー", systemImage: "photo.on.rectangle")
                    }
                    .tag(4)
                    .onChange(of: navigationModel.selectedTab) { newValue in
                        if newValue == 4 {
                            // プレビュータブが選択されたときにセッションを更新
                            previewViewModel.loadSessions()
                        }
                    }
                
                // フレームレートテストタブ
                FrameRateTestView(viewModel: viewModel)
                    .tabItem {
                        Label("フレームレートテスト", systemImage: "chart.xyaxis.line")
                    }
                    .tag(3)
            }
        }
        .environmentObject(navigationModel)
        .onAppear {
            // キャプチャ完了通知の購読
            NotificationCenter.default.addObserver(
                forName: .captureCompleted,
                object: nil,
                queue: .main
            ) { _ in
                // キャプチャ完了時に、プレビュータブを選択してセッションリストを更新
                navigationModel.selectedTab = 4
                previewViewModel.loadSessions()
            }
            
            Task {
                await viewModel.loadAvailableTargets()
            }
        }
    }
}

// Settings panel view
struct SettingsView: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    
    // 各セクションの折りたたみ状態
    @State private var isTargetTypeExpanded = true
    @State private var isTargetSelectionExpanded = true
    @State private var isSettingsExpanded = true
    @State private var isStatsExpanded = true
    @State private var isControlsExpanded = true
    
    var body: some View {
        ScrollView {
            VStack(spacing: 8) { // スペーシングを縮小
                // Capture target type selection section
                DisclosureGroup(
                    isExpanded: $isTargetTypeExpanded,
                    content: {
                        VStack(alignment: .leading) {
                            Picker("Display", selection: $viewModel.captureTargetType) {
                                Text("All").tag(MediaCapture.CaptureTargetType.all)
                                Text("Screens Only").tag(MediaCapture.CaptureTargetType.screen)
                                Text("Windows Only").tag(MediaCapture.CaptureTargetType.window)
                            }
                            .pickerStyle(SegmentedPickerStyle())
                        }
                        .padding(.vertical, 1)
                    },
                    label: {
                        HStack {
                            Image(systemName: "display.2")
                                .foregroundColor(.blue)
                            Text("Capture Target Type")
                                .font(.headline)
                        }
                    }
                )
                .padding(8)
                .background(Color(.windowBackgroundColor).opacity(0.5))
                .cornerRadius(8)
                
                // Capture target selection section
                DisclosureGroup(
                    isExpanded: $isTargetSelectionExpanded,
                    content: {
                        TargetSelectionSectionContent(viewModel: viewModel)
                    },
                    label: {
                        HStack {
                            Image(systemName: "list.bullet")
                                .foregroundColor(.blue)
                            Text("Capture Target")
                                .font(.headline)
                        }
                    }
                )
                .padding(8)
                .background(Color(.windowBackgroundColor).opacity(0.5))
                .cornerRadius(8)
                
                // Capture settings section
                DisclosureGroup(
                    isExpanded: $isSettingsExpanded,
                    content: {
                        CaptureSettingsSectionContent(viewModel: viewModel)
                    },
                    label: {
                        HStack {
                            Image(systemName: "gear")
                                .foregroundColor(.blue)
                            Text("Capture Settings")
                                .font(.headline)
                        }
                    }
                )
                .padding(8)
                .background(Color(.windowBackgroundColor).opacity(0.5))
                .cornerRadius(8)
                
                // Statistics section
                DisclosureGroup(
                    isExpanded: $isStatsExpanded,
                    content: {
                        StatsSectionContent(viewModel: viewModel)
                    },
                    label: {
                        HStack {
                            Image(systemName: "chart.bar")
                                .foregroundColor(.blue)
                            Text("Statistics")
                                .font(.headline)
                        }
                    }
                )
                .padding(8)
                .background(Color(.windowBackgroundColor).opacity(0.5))
                .cornerRadius(8)
                
                // Capture control section
                DisclosureGroup(
                    isExpanded: $isControlsExpanded,
                    content: {
                        ControlSectionContent(viewModel: viewModel)
                    },
                    label: {
                        HStack {
                            Image(systemName: "record.circle")
                                .foregroundColor(.blue)
                            Text("Controls")
                                .font(.headline)
                        }
                    }
                )
                .padding(8)
                .background(Color(.windowBackgroundColor).opacity(0.5))
                .cornerRadius(8)
            }
            .padding(8)
        }
    }
}

// 元の構造体からコンテンツのみ抽出したコンポーネント
struct TargetSelectionSectionContent: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if viewModel.isLoading {
                ProgressView("Loading...")
                    .padding(.vertical, 2)
            } else if viewModel.filteredTargets.isEmpty {
                Text("No available capture targets")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 2)
            } else {
                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    
                    TextField("Search", text: $viewModel.searchText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                .padding(.bottom, 2)
                
                // Target count display based on type
                Text(getCaptureTargetCountText())
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 2)
                
                // Capture target list
                Picker("Capture Target", selection: $viewModel.selectedTargetIndex) {
                    ForEach(0..<viewModel.filteredTargets.count, id: \.self) { index in
                        Text(getTargetDisplayName(viewModel.filteredTargets[index]))
                            .tag(index)
                    }
                }
                .labelsHidden()
                .frame(height: 100)
                
                // Display details for selected capture target
                if viewModel.selectedTargetIndex < viewModel.filteredTargets.count {
                    let target = viewModel.filteredTargets[viewModel.selectedTargetIndex]
                    TargetDetailView(target: target)
                }
            }
            
            // Update capture targets button
            HStack {
                Spacer()
                Button("Refresh") {
                    Task {
                        await viewModel.loadAvailableTargets()
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(4)
    }
    
    // 以前のメソッドをそのまま移行
    private func getCaptureTargetCountText() -> String {
        let totalScreens = viewModel.availableScreens.count
        let totalWindows = viewModel.availableWindows.count
        
        switch viewModel.captureTargetType {
        case .screen:
            return "Screens: \(totalScreens)"
        case .window:
            return "Windows: \(totalWindows)"
        case .all:
            return "Screens: \(totalScreens), Windows: \(totalWindows)"
        }
    }
    
    private func getTargetDisplayName(_ target: MediaCaptureTarget) -> String {
        if target.isDisplay {
            return "Screen: \(target.title ?? "Display \(target.displayID)")"
        } else {
            if let appName = target.applicationName, !appName.isEmpty {
                return "Window: \(appName) - \(target.title ?? "Untitled")"
            } else {
                return "Window: \(target.title ?? "Untitled")"
            }
        }
    }
}

// Target detail view
struct TargetDetailView: View {
    let target: MediaCaptureTarget
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {  // spacing を 4 → 2 に縮小
            Divider()
                .padding(.vertical, 1)  // .vertical パディングを縮小 (2 → 1)
                
            if target.isDisplay {
                Text("Display Information:")
                    .font(.caption)
                    .bold()
                Text("ID: \(target.displayID)")
                    .font(.caption)
                Text("Resolution: \(Int(target.frame.width)) × \(Int(target.frame.height))")
                    .font(.caption)
            } else {
                Text("Window Information:")
                    .font(.caption)
                    .bold()
                if let appName = target.applicationName, !appName.isEmpty {
                    Text("Application: \(appName)")
                        .font(.caption)
                }
                Text("Title: \(target.title ?? "Untitled")")
                    .font(.caption)
                Text("Size: \(Int(target.frame.width)) × \(Int(target.frame.height))")
                    .font(.caption)
            }
        }
        .padding(.top, 1)  // .top パディングを縮小 (2 → 1)
    }
}

// Capture settings section
struct CaptureSettingsSectionContent: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    
    var body: some View {
        VStack(spacing: 10) {
            Toggle("Audio Only (0 FPS)", isOn: $viewModel.audioOnly)
            
            if !viewModel.audioOnly {
                Picker("Quality", selection: $viewModel.selectedQuality) {
                    Text("High").tag(0)
                    Text("Medium").tag(1)
                    Text("Low").tag(2)
                }
                .pickerStyle(.segmented)
                
                // Frame rate mode selection
                Picker("Frame Rate Mode", selection: $viewModel.frameRateMode) {
                    Text("Standard").tag(0)
                    Text("Low").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 4)
                
                VStack {
                    HStack {
                        // Display changes based on mode
                        if viewModel.frameRateMode == 0 {
                            Text("Frame Rate: \(Int(viewModel.frameRate)) fps")
                        } else {
                            // Low mode shows "every X seconds"
                            let interval = 1.0 / viewModel.lowFrameRate
                            Text("Interval: Every \(String(format: "%.1f", interval)) seconds")
                        }
                        Spacer()
                    }
                    
                    if viewModel.frameRateMode == 0 {
                        // Standard mode: 1-60fps
                        Slider(value: $viewModel.frameRate, in: 1...60, step: 1)
                    } else {
                        // Low mode: 0.1-0.9fps (every 10-1.1 seconds)
                        Slider(value: $viewModel.lowFrameRate, in: 0.1...0.9, step: 0.1)
                    }
                }
                
                // Preset selection (for low mode)
                if viewModel.frameRateMode == 1 {
                    HStack(spacing: 12) {
                        Button("Every 1s") { viewModel.lowFrameRate = 0.9 }
                        Button("Every 2s") { viewModel.lowFrameRate = 0.5 }
                        Button("Every 3s") { viewModel.lowFrameRate = 0.33 }
                        Button("Every 5s") { viewModel.lowFrameRate = 0.2 }
                        Button("Every 10s") { viewModel.lowFrameRate = 0.1 }
                    }
                    .buttonStyle(.bordered)
                    .font(.footnote)
                }
            }
        }
    }
}

// Statistics section
struct StatsSectionContent: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Received Frames:")
                Spacer()
                Text("\(viewModel.frameCount)")
            }
            
            HStack {
                Text("FPS:")
                Spacer()
                Text(String(format: "%.1f", viewModel.currentFPS))
            }
            
            HStack {
                Text("Image Size:")
                Spacer()
                Text(viewModel.imageSize)
            }
            
            HStack {
                Text("Audio Sample Rate:")
                Spacer()
                Text("\(Int(viewModel.audioSampleRate)) Hz")
            }
            
            HStack {
                Text("Latency:")
                Spacer()
                Text(String(format: "%.1f ms", viewModel.captureLatency))
            }
        }
    }
}

// Capture control section
struct ControlSectionContent: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    @EnvironmentObject var navigationModel: NavigationViewModel
    
    var body: some View {
        VStack(spacing: 8) {
            // Capture controls
            HStack {
                Spacer()
                Button(viewModel.isCapturing ? "Stop Capture" : "Start Capture") {
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
            
            // 生データ保存オプション
            Divider()
            
            HStack {
                Toggle("キャプチャの生データを保存する", isOn: $viewModel.rawDataSavingEnabled)
                    .disabled(viewModel.isCapturing)
                    .help("音声バッファと画像フレームの生データをディスクに保存します")
                
                Spacer()
            }
            
            // キャプチャ中に保存状況を表示
            if viewModel.isCapturing && viewModel.rawDataSavingEnabled {
                HStack {
                    Text("保存済み: \(viewModel.savedFrameCount)フレーム, \(viewModel.savedAudioDataSize)KB音声")
                        .font(.caption)
                    
                    if viewModel.isSavingData {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
                }
                .padding(.top, 2)
            }
            
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.footnote)
            }
        }
    }
}

// Preview area view
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

// Waiting view
struct WaitingView: View {
    var body: some View {
        VStack {
            Image(systemName: "display")
                .font(.system(size: 80))
                .foregroundColor(.gray)
            Text("Waiting for Capture...")
                .font(.title2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.05))
    }
}

#Preview {
    ContentView()
}
