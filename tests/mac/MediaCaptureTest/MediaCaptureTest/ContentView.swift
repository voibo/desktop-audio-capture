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
            SettingsView(viewModel: viewModel)
                .frame(minWidth: 300)
                .listStyle(.sidebar)
            
            PreviewView(viewModel: viewModel)
                .padding()
                .frame(minWidth: 500, minHeight: 400)
        }
        .navigationTitle("MediaCapture")
        .frame(minWidth: 900, minHeight: 600)
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
        List {
            // Capture target selection section
            TargetSelectionSection(viewModel: viewModel)
            
            // Capture settings section
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
        Section(header: Text("Capture Target")) {
            if viewModel.isLoading {
                ProgressView("Loading...")
            } else if viewModel.availableTargets.isEmpty {
                Text("No available capture targets")
                    .foregroundStyle(.secondary)
            } else {
                TextField("Search", text: $viewModel.searchText)
                
                Picker("Capture Target", selection: $viewModel.selectedTargetIndex) {
                    ForEach(Array(viewModel.filteredTargets.enumerated()), id: \.offset) { index, target in
                        Text(targetTitle(target)).tag(index)
                    }
                }
                .pickerStyle(.menu)
            }
            
            Button("Refresh Capture Targets") {
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
                return "Window \(target.windowID)"
            }
        } else if target.isDisplay {
            return target.title ?? "Display \(target.displayID)"
        } else {
            return "Unknown Target"
        }
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
            VStack(alignment: .leading, spacing: 8) {
                Text("Audio Level")
                
                // Audio level meter
                AudioLevelMeter(level: viewModel.audioLevel)
                    .frame(height: 20)
                
                // Audio waveform display
                Text("Audio Waveform (Recent Changes)")
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
    
    // Change waveform color based on audio level
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
