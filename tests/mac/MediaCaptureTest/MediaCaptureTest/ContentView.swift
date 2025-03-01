import SwiftUI
import AVFoundation
import ScreenCaptureKit

struct ContentView: View {
    @StateObject private var viewModel = MediaCaptureViewModel()
    
    var body: some View {
        NavigationView {
            SettingsView(viewModel: viewModel)
                .frame(minWidth: 300)
                .listStyle(.sidebar)
            
            VStack(spacing: 0) {
                // Top area: Current preview
                PreviewView(viewModel: viewModel)
                    .padding()
                    .frame(height: 400)
                
                Divider()
                
                // Bottom area: Timeline view
                CaptureTimelineView(viewModel: viewModel)
                    .frame(minHeight: 300)
                    .padding()
            }
            .frame(minWidth: 500)
        }
        .navigationTitle("MediaCapture")
        .frame(minWidth: 900, minHeight: 900)
        .onAppear {
            Task {
                await viewModel.loadAvailableTargets()
            }
        }
    }
}

// Settings panel view
struct SettingsView: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    
    var body: some View {
        VStack(spacing: 16) {
            // Capture target type selection section
            GroupBox(label: Text("Capture Target Type")) {
                VStack(alignment: .leading) {
                    Picker("Display", selection: $viewModel.captureTargetType) {
                        Text("All").tag(MediaCapture.CaptureTargetType.all)
                        Text("Screens Only").tag(MediaCapture.CaptureTargetType.screen)
                        Text("Windows Only").tag(MediaCapture.CaptureTargetType.window)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
                .padding(.vertical, 1)
            }
            
            // Capture target selection section
            TargetSelectionSection(viewModel: viewModel)
            
            // Capture settings
            CaptureSettingsSection(viewModel: viewModel)
            
            // Statistics section
            StatsSection(viewModel: viewModel)
            
            // Capture control section
            ControlSection(viewModel: viewModel)
        }
    }
}

// Capture target selection section
struct TargetSelectionSection: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    
    var body: some View {
        GroupBox(label: Text("Capture Target")) {
            VStack(alignment: .leading, spacing: 10) {
                if viewModel.isLoading {
                    ProgressView("Loading...")
                        .padding(.vertical)
                } else if viewModel.filteredTargets.isEmpty {
                    Text("No available capture targets")
                        .foregroundColor(.secondary)
                        .padding(.vertical)
                } else {
                    // Search field
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        
                        TextField("Search", text: $viewModel.searchText)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    .padding(.bottom, 5)
                    
                    // Target count display based on type
                    Text(getCaptureTargetCountText())
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 5)
                    
                    // Capture target list
                    Picker("Capture Target", selection: $viewModel.selectedTargetIndex) {
                        ForEach(0..<viewModel.filteredTargets.count, id: \.self) { index in
                            Text(getTargetDisplayName(viewModel.filteredTargets[index]))
                                .tag(index)
                        }
                    }
                    .labelsHidden()
                    .frame(height: 120)
                    
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
                .padding(.top, 5)
            }
            .padding(8)
        }
    }
    
    // Generate capture target count text
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
    
    // Get display name for a capture target
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
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .padding(.vertical, 2)
                
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
        .padding(.top, 2)
    }
}

// Capture settings section
struct CaptureSettingsSection: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    
    var body: some View {
        Section(header: Text("Capture Settings")) {
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
struct StatsSection: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    
    var body: some View {
        Section(header: Text("Statistics")) {
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
struct ControlSection: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    
    var body: some View {
        Section {
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
            
            // Audio recording status display
            if viewModel.isCapturing && viewModel.isAudioRecording {
                Divider()
                
                // Recording status display
                HStack {
                    Label(
                        "Recording Audio: \(String(format: "%.1f sec", viewModel.audioRecordingTime))", 
                        systemImage: "waveform"
                    )
                    .foregroundColor(.red)
                    
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            
            // Saved audio file information (displayed regardless of capture state)
            if let audioFileURL = viewModel.audioFileURL {
                Divider()
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved Raw Data (PCM):")
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
                        // Show file location
                        Button(action: {
                            NSWorkspace.shared.selectFile(audioFileURL.path, inFileViewerRootedAtPath: "")
                        }) {
                            Label("Show in Finder", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        
                        // Copy command to clipboard
                        Button(action: {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(viewModel.getFFplayCommand(), forType: .string)
                            viewModel.errorMessage = "ffplay command copied to clipboard"
                        }) {
                            Label("ffplay Command", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                        
                        // Mono conversion button
                        Button("Convert to Mono") {
                            viewModel.saveAudioToMonoFile()
                        }
                        .help("Convert stereo audio to mono and save")
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

// Audio-only mode view
struct AudioOnlyView: View {
    var level: Float
    
    var body: some View {
        VStack {
            Image(systemName: "waveform")
                .font(.system(size: 80))
                .foregroundColor(.green.opacity(0.6 + Double(level) * 0.4))
                .animation(.easeInOut(duration: 0.1), value: level)
            Text("Audio Capture Active")
                .font(.title2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.05))
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

// Audio level visualization view
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

// Audio waveform display view
struct AudioWaveformView: View {
    var levels: [Float]
    var color: Color = .green
    
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                let stepX = width / CGFloat(levels.count - 1)
                
                // Waveform center line
                let centerY = height / 2
                
                // Set first point
                path.move(to: CGPoint(x: 0, y: centerY - CGFloat(levels[0]) * centerY))
                
                // Add remaining points
                for i in 1..<levels.count {
                    let x = CGFloat(i) * stepX
                    let y = centerY - CGFloat(levels[i]) * centerY
                    
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                
                // Close the waveform (bottom portion)
                path.addLine(to: CGPoint(x: width, y: centerY + CGFloat(levels[levels.count - 1]) * centerY))
                
                // Add bottom points in reverse order
                for i in (0..<levels.count-1).reversed() {
                    let x = CGFloat(i) * stepX
                    let y = centerY + CGFloat(levels[i]) * centerY
                    
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                
                // Close the path
                path.closeSubpath()
            }
            .fill(
                LinearGradient(
                    gradient: Gradient(colors: [color.opacity(0.5), color.opacity(0.2)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            
            // Line (top edge)
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                let stepX = width / CGFloat(levels.count - 1)
                
                // Waveform center line
                let centerY = height / 2
                
                // Set first point
                path.move(to: CGPoint(x: 0, y: centerY - CGFloat(levels[0]) * centerY))
                
                // Add remaining points
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
