//
//  CaptureTimelineView.swift
//  MediaCaptureTest
//
//  Created for Desktop Audio Capture
//

import SwiftUI
import AVFoundation

struct CaptureTimelineView: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            // Timeline control bar
            HStack {
                // Toggle recording to timeline
                Button(action: {
                    viewModel.toggleTimelineCapturing(!viewModel.isTimelineCapturingEnabled)
                }) {
                    Image(systemName: viewModel.isTimelineCapturingEnabled ? "stop.circle.fill" : "record.circle")
                        .foregroundColor(viewModel.isTimelineCapturingEnabled ? .red : .primary)
                }
                .help(viewModel.isTimelineCapturingEnabled ? "Stop Timeline Recording" : "Start Timeline Recording")
                .buttonStyle(.borderless)
                .font(.title)
                
                Spacer()
                
                // Timeline information
                Text("Timeline: \(formatTimeCode(viewModel.timelineCurrentPosition)) / \(formatTimeCode(viewModel.timelineTotalDuration))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                // Zoom controls
                Button(action: {
                    withAnimation { viewModel.timelineZoomLevel = max(0.5, viewModel.timelineZoomLevel - 0.5) }
                }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(viewModel.timelineZoomLevel <= 0.5)
                .buttonStyle(.borderless)
                
                Text("Zoom: \(Int(viewModel.timelineZoomLevel * 100))%")
                    .frame(width: 80)
                    .font(.caption)
                
                Button(action: {
                    withAnimation { viewModel.timelineZoomLevel = min(3.0, viewModel.timelineZoomLevel + 0.5) }
                }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .disabled(viewModel.timelineZoomLevel >= 3.0)
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            
            // Main timeline area
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    // Top: Thumbnails
                    ThumbnailTimelineView(
                        viewModel: viewModel,
                        width: geometry.size.width
                    )
                    .frame(height: geometry.size.height * 0.4)
                    
                    Divider()
                    
                    // Bottom: Audio waveform
                    AudioTimelineView(
                        viewModel: viewModel,
                        width: geometry.size.width
                    )
                    .frame(height: geometry.size.height * 0.6)
                }
                
                // Playhead overlay
                TimelinePlayheadView(
                    currentPosition: viewModel.timelineCurrentPosition,
                    totalDuration: viewModel.timelineTotalDuration,
                    width: geometry.size.width,
                    height: geometry.size.height,
                    zoom: viewModel.timelineZoomLevel
                )
            }
            .padding(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // Format time as MM:SS.ms
    private func formatTimeCode(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let milliseconds = Int((time.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%01d", minutes, seconds, milliseconds)
    }
}

// Thumbnail timeline view
struct ThumbnailTimelineView: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    let width: CGFloat
    
    var body: some View {
        ZStack {
            // Background
            Rectangle()
                .fill(Color.black.opacity(0.05))
            
            // Thumbnail display
            ScrollViewReader { scrollView in
                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        // Time markers
                        TimeMarkersView(
                            totalDuration: viewModel.timelineTotalDuration,
                            width: width * viewModel.timelineZoomLevel,
                            isTop: true
                        )
                        
                        // Thumbnails
                        HStack(spacing: 0) {
                            ForEach(viewModel.timelineThumbnails) { thumbnail in
                                ThumbnailView(thumbnail: thumbnail)
                                    .frame(
                                        width: thumbnailWidth,
                                        height: 100
                                    )
                                    .offset(x: calculateOffset(for: thumbnail.timestamp))
                            }
                        }
                        .frame(width: width * viewModel.timelineZoomLevel, alignment: .leading)
                    }
                    .id("timeline")
                }
                .onChange(of: viewModel.timelineCurrentPosition) { oldValue, newValue in
                    // Auto-scroll timeline to keep current position visible
                    if viewModel.isTimelineCapturingEnabled {
                        withAnimation {
                            scrollView.scrollTo("timeline", anchor: .trailing)
                        }
                    }
                }
            }
        }
    }
    
    private var thumbnailWidth: CGFloat { 100 }
    
    private func calculateOffset(for timestamp: TimeInterval) -> CGFloat {
        let totalWidth = width * viewModel.timelineZoomLevel
        return (timestamp / viewModel.timelineTotalDuration) * totalWidth - (thumbnailWidth / 2)
    }
}

// Individual thumbnail view
struct ThumbnailView: View {
    let thumbnail: MediaCaptureViewModel.TimelineThumbnail
    
    var body: some View {
        VStack {
            Image(nsImage: thumbnail.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 90, height: 60)
                .cornerRadius(4)
                .clipped()
                .shadow(radius: 1)
            
            Text(formatTimestamp(thumbnail.timestamp))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
    
    private func formatTimestamp(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// Audio timeline view
struct AudioTimelineView: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    let width: CGFloat
    
    var body: some View {
        ZStack {
            // Background
            Rectangle()
                .fill(Color.black.opacity(0.02))
            
            ScrollViewReader { scrollView in
                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        // Time markers
                        TimeMarkersView(
                            totalDuration: viewModel.timelineTotalDuration,
                            width: width * viewModel.timelineZoomLevel,
                            isTop: false
                        )
                        
                        // Audio waveform
                        AudioWaveformTimelineView(
                            samples: viewModel.timelineAudioSamples,
                            width: width * viewModel.timelineZoomLevel
                        )
                    }
                    .id("audio")
                }
                .onChange(of: viewModel.timelineCurrentPosition) { oldValue, newValue in
                    // Auto-scroll timeline to keep current position visible
                    if viewModel.isTimelineCapturingEnabled {
                        withAnimation {
                            scrollView.scrollTo("audio", anchor: .trailing)
                        }
                    }
                }
            }
        }
    }
}

// Audio waveform renderer for timeline
struct AudioWaveformTimelineView: View {
    let samples: [Float]
    let width: CGFloat
    
    var body: some View {
        Canvas { context, size in
            // Don't draw if no samples
            guard !samples.isEmpty else { return }
            
            let centerY = size.height / 2
            let stepX = width / CGFloat(max(1, samples.count - 1))
            let maxAmplitude = centerY * 0.8  // 80% of half height
            
            var path = Path()
            
            // Draw top part of waveform
            path.move(to: CGPoint(x: 0, y: centerY - CGFloat(samples.first ?? 0) * maxAmplitude))
            
            for (i, sample) in samples.enumerated() {
                let x = CGFloat(i) * stepX
                let y = centerY - CGFloat(sample) * maxAmplitude
                path.addLine(to: CGPoint(x: x, y: y))
            }
            
            // Draw bottom part of waveform
            path.addLine(to: CGPoint(x: CGFloat(samples.count - 1) * stepX, y: centerY))
            
            for (i, sample) in samples.enumerated().reversed() {
                let x = CGFloat(i) * stepX
                let y = centerY + CGFloat(sample) * maxAmplitude
                path.addLine(to: CGPoint(x: x, y: y))
            }
            
            path.closeSubpath()
            
            // Fill with gradient
            let gradient = Gradient(colors: [
                Color.blue.opacity(0.5),
                Color.blue.opacity(0.2)
            ])
            
            context.fill(
                path,
                with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            
            // Draw top line
            var topPath = Path()
            topPath.move(to: CGPoint(x: 0, y: centerY - CGFloat(samples.first ?? 0) * maxAmplitude))
            
            for (i, sample) in samples.enumerated() {
                let x = CGFloat(i) * stepX
                let y = centerY - CGFloat(sample) * maxAmplitude
                topPath.addLine(to: CGPoint(x: x, y: y))
            }
            
            context.stroke(topPath, with: .color(.blue), lineWidth: 1.5)
        }
        .frame(width: width)
    }
}

// Time markers view
struct TimeMarkersView: View {
    let totalDuration: TimeInterval
    let width: CGFloat
    let isTop: Bool
    
    var body: some View {
        Canvas { context, size in
            let height = size.height
            let secondWidth = width / CGFloat(totalDuration)
            
            // Calculate appropriate interval based on zoom level
            let secondsPerMark: Int
            if secondWidth < 5 {
                secondsPerMark = 60  // One mark per minute
            } else if secondWidth < 15 {
                secondsPerMark = 30  // One mark per 30 seconds
            } else if secondWidth < 30 {
                secondsPerMark = 10  // One mark per 10 seconds
            } else {
                secondsPerMark = 5   // One mark per 5 seconds
            }
            
            let markerCount = Int(totalDuration) / secondsPerMark + 1
            
            for i in 0...markerCount {
                let seconds = i * secondsPerMark
                let x = CGFloat(seconds) * secondWidth
                
                // Don't draw markers beyond width
                if x > width {
                    break
                }
                
                // Draw time marker line
                var path = Path()
                if isTop {
                    path.move(to: CGPoint(x: x, y: height - 15))
                    path.addLine(to: CGPoint(x: x, y: height))
                } else {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: 15))
                }
                
                context.stroke(path, with: .color(.gray.opacity(0.5)), lineWidth: 1)
                
                // Draw time text
                let minutes = seconds / 60
                let remainingSeconds = seconds % 60
                let timeString = String(format: "%d:%02d", minutes, remainingSeconds)
                
                let text = Text(timeString)
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                
                let textPoint: CGPoint
                if isTop {
                    textPoint = CGPoint(x: x - 12, y: height - 16)
                } else {
                    textPoint = CGPoint(x: x - 12, y: 16)
                }
                
                context.draw(text, at: textPoint)
            }
        }
        .frame(width: width)
    }
}

// Playhead vertical line
struct TimelinePlayheadView: View {
    let currentPosition: TimeInterval
    let totalDuration: TimeInterval
    let width: CGFloat
    let height: CGFloat
    let zoom: Double
    
    var body: some View {
        GeometryReader { geometry in
            let x = (currentPosition / totalDuration) * width * zoom
            
            // Vertical playhead line
            Rectangle()
                .fill(Color.red)
                .frame(width: 1.5)
                .frame(height: height)
                .position(x: min(x, width), y: height / 2)
            
            // Current position indicator
            Text(formatCurrentPosition(currentPosition))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.red)
                .cornerRadius(3)
                .position(x: min(x, width), y: 10)
        }
    }
    
    private func formatCurrentPosition(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let milliseconds = Int((time.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%01d", minutes, seconds, milliseconds)
    }
}

#Preview {
    CaptureTimelineView(viewModel: MediaCaptureViewModel())
        .frame(width: 800, height: 300)
}