import SwiftUI
import AVFoundation

struct CaptureTimelineView: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    @State private var isAutoScrolling = true
    
    var body: some View {
        VStack(spacing: 0) {
            // Control bar
            HStack {
                // Timeline control button
                Button(action: {
                    viewModel.toggleTimelineCapturing(!viewModel.isTimelineCapturingEnabled)
                }) {
                    Image(systemName: viewModel.isTimelineCapturingEnabled ? "stop.circle.fill" : "record.circle")
                        .foregroundColor(viewModel.isTimelineCapturingEnabled ? .red : .primary)
                }
                .help(viewModel.isTimelineCapturingEnabled ? "Stop timeline recording" : "Start timeline recording")
                .buttonStyle(.borderless)
                .font(.title)
                
                // Auto-scroll toggle
                Toggle(isOn: $isAutoScrolling) {
                    Text("Auto-scroll")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                
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
            .padding(.bottom, 8)
            
            // Main timeline area
            GeometryReader { geometry in
                ScrollViewReader { scrollView in
                    ScrollView(.horizontal, showsIndicators: true) {
                        UnifiedTimelineView(
                            viewModel: viewModel,
                            width: calculateTimelineWidth(for: geometry),
                            height: geometry.size.height
                        )
                        .id("timeline")
                    }
                    .onChange(of: viewModel.timelineCurrentPosition) { oldValue, newValue in
                        // Only scroll if auto-scroll is enabled
                        if isAutoScrolling && viewModel.isTimelineCapturingEnabled {
                            withAnimation {
                                scrollView.scrollTo("timeline", anchor: .trailing)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // Calculate timeline width based on zoom level
    private func calculateTimelineWidth(for geometry: GeometryProxy) -> CGFloat {
        let baseWidth = max(geometry.size.width, 800)
        return baseWidth * CGFloat(viewModel.timelineZoomLevel)
    }
    
    // Format time as MM:SS.ms
    private func formatTimeCode(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let milliseconds = Int((time.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%01d", minutes, seconds, milliseconds)
    }
}

// Unified timeline view that combines all elements
struct UnifiedTimelineView: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    let width: CGFloat
    let height: CGFloat
    @State private var isDragging = false
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background grid
            TimelineGridView(
                totalDuration: viewModel.timelineTotalDuration,
                width: width,
                height: height
            )
            
            // Main content
            VStack(spacing: 0) {
                // Thumbnail area
                ZStack(alignment: .topLeading) {
                    // Thumbnail background
                    Rectangle()
                        .fill(Color.black.opacity(0.05))
                        .frame(height: height * 0.4)
                    
                    // Thumbnail placement
                    ForEach(viewModel.timelineThumbnails) { thumbnail in
                        ZStack(alignment: .bottomLeading) {
                            // Timeline marker at timestamp position
                            Rectangle()
                                .fill(Color.gray.opacity(0.5))
                                .frame(width: 1, height: height * 0.1)
                                .offset(y: -5)
                            
                            ThumbnailView(thumbnail: thumbnail)
                                .frame(width: thumbnailWidth)
                        }
                        .position(
                            x: positionForTime(thumbnail.timestamp),
                            y: height * 0.2
                        )
                        .zIndex(1)
                    }
                }
                .frame(height: height * 0.4)
                
                Divider()
                
                // Waveform area
                ZStack(alignment: .topLeading) {
                    // Waveform background
                    Rectangle()
                        .fill(Color.black.opacity(0.02))
                        .frame(height: height * 0.6)
                    
                    // Waveform display
                    ImprovedWaveformView(
                        samples: viewModel.timelineAudioSamples,
                        currentTime: viewModel.timelineCurrentPosition,
                        totalDuration: viewModel.timelineTotalDuration,
                        width: width,
                        height: height * 0.6
                    )
                }
                .frame(height: height * 0.6)
            }
            
            // Playhead display
            TimelinePlayheadView(
                currentPosition: viewModel.timelineCurrentPosition,
                totalDuration: viewModel.timelineTotalDuration,
                width: width,
                height: height
            )
            
            // Transparent overlay for scrubbing
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: width, height: height)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            // Pause if timeline is playing
                            if viewModel.isPlaying {
                                viewModel.stopPlayback()
                            }
                            
                            // Calculate time from drag position
                            let newPosition = timeForPosition(value.location.x)
                            viewModel.timelineCurrentPosition = newPosition
                            
                            // Update preview image
                            viewModel.updatePreviewImageForPosition(newPosition)
                        }
                        .onEnded { value in
                            // Only update position, don't start playback
                            let position = timeForPosition(value.location.x)
                            viewModel.timelineCurrentPosition = position
                            isDragging = false
                        }
                )
        }
        .frame(width: width, height: height)
        .overlay(
            // Playback controls overlay
            VStack {
                Spacer()
                HStack {
                    // Maintain stop button (needed if already playing)
                    if viewModel.isPlaying {
                        Button(action: {
                            viewModel.stopPlayback()
                        }) {
                            Image(systemName: "stop.fill")
                                .font(.title)
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Circle().fill(Color.red))
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Spacer()
                    
                    // Current time display
                    Text(formatTimeCode(viewModel.timelineCurrentPosition))
                        .font(.caption)
                        .padding(6)
                        .background(Capsule().fill(Color.black.opacity(0.5)))
                        .foregroundColor(.white)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        )
    }
    
    // Thumbnail width
    private var thumbnailWidth: CGFloat { 120 }
    
    // Convert time to position
    private func positionForTime(_ time: TimeInterval) -> CGFloat {
        return (time / viewModel.timelineTotalDuration) * width
    }
    
    // Convert position to time
    private func timeForPosition(_ x: CGFloat) -> TimeInterval {
        let normalized = max(0, min(1, x / width))
        return normalized * viewModel.timelineTotalDuration
    }
    
    // Format time as MM:SS.ms
    private func formatTimeCode(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let milliseconds = Int((time.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%01d", minutes, seconds, milliseconds)
    }
}

// Timeline grid view
struct TimelineGridView: View {
    let totalDuration: TimeInterval
    let width: CGFloat
    let height: CGFloat
    
    var body: some View {
        Canvas { context, size in
            // Calculate vertical time markers
            let secondWidth = width / CGFloat(totalDuration)
            
            // Calculate interval based on zoom level
            let secondsPerMark: Int
            if secondWidth < 5 {
                secondsPerMark = 60  // 1 minute interval
            } else if secondWidth < 15 {
                secondsPerMark = 30  // 30 second interval
            } else if secondWidth < 30 {
                secondsPerMark = 10  // 10 second interval
            } else {
                secondsPerMark = 5   // 5 second interval
            }
            
            let markerCount = Int(totalDuration) / secondsPerMark + 1
            
            // Draw time markers
            for i in 0...markerCount {
                let seconds = i * secondsPerMark
                let x = CGFloat(seconds) * secondWidth
                
                // Don't draw markers beyond width
                if x > width {
                    break
                }
                
                // Draw vertical line
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: height))
                
                context.stroke(path, with: .color(.gray.opacity(0.2)), lineWidth: 1)
                
                // Draw time text
                let minutes = seconds / 60
                let remainingSeconds = seconds % 60
                let timeString = String(format: "%d:%02d", minutes, remainingSeconds)
                
                let text = Text(timeString)
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                
                context.draw(text, at: CGPoint(x: x + 4, y: 4))
            }
            
            // Horizontal level lines for waveform area
            let waveformTop = size.height * 0.4
            let waveformHeight = size.height * 0.6
            let waveformCenter = waveformTop + waveformHeight / 2
            
            // Center line (zero level)
            var centerPath = Path()
            centerPath.move(to: CGPoint(x: 0, y: waveformCenter))
            centerPath.addLine(to: CGPoint(x: width, y: waveformCenter))
            context.stroke(centerPath, with: .color(.gray.opacity(0.4)), lineWidth: 1)
            
            // Level guidelines
            let levels = [0.25, 0.5, 0.75]
            for level in levels {
                var topPath = Path()
                let topY = waveformCenter - (waveformHeight / 2 * CGFloat(level))
                topPath.move(to: CGPoint(x: 0, y: topY))
                topPath.addLine(to: CGPoint(x: width, y: topY))
                
                var bottomPath = Path()
                let bottomY = waveformCenter + (waveformHeight / 2 * CGFloat(level))
                bottomPath.move(to: CGPoint(x: 0, y: bottomY))
                bottomPath.addLine(to: CGPoint(x: width, y: bottomY))
                
                context.stroke(topPath, with: .color(.gray.opacity(0.15)), lineWidth: 0.5)
                context.stroke(bottomPath, with: .color(.gray.opacity(0.15)), lineWidth: 0.5)
            }
        }
        .frame(width: width, height: height)
    }
}

// Thumbnail view
struct ThumbnailView: View {
    let thumbnail: MediaCaptureViewModel.TimelineThumbnail
    
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: thumbnail.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 110, height: 70)
                .cornerRadius(4)
                .clipped()
                .shadow(radius: 1)
                .overlay(
                    // Marker showing timestamp position at left edge
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 2, height: 5)
                        .offset(y: 35),
                    alignment: .bottomLeading
                )
            
            Text(formatTimestamp(thumbnail.timestamp))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(2)
                .background(Color.white.opacity(0.7))
                .cornerRadius(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    private func formatTimestamp(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// Improved waveform view
struct ImprovedWaveformView: View {
    let samples: [Float]
    let currentTime: TimeInterval
    let totalDuration: TimeInterval
    let width: CGFloat
    let height: CGFloat
    
    var body: some View {
        Canvas { context, size in
            // Don't draw if no samples or invalid duration
            guard !samples.isEmpty, totalDuration > 0 else { return }
            
            let centerY = size.height / 2
            
            // Waveform scaling settings
            let maxAmplitude = centerY * 0.4
            let maxSampleValue = samples.map { abs($0) }.max() ?? 1.0
            let scaleFactor: Float = maxSampleValue > 0.3 ? min(1.0, 0.6 / maxSampleValue) : 2.0
            
            // Time to pixel conversion
            let pixelsPerSecond = width / CGFloat(totalDuration)
            
            // Sample rate estimation based on current time
            // Samples should only exist up to current time
            let effectiveDuration = min(currentTime, totalDuration)
            let estimatedSampleRate = samples.count > 0 ? Double(samples.count) / effectiveDuration : 44100.0
            
            // Drawing paths
            var path = Path()
            var topPath = Path()
            
            // Set initial points
            path.move(to: CGPoint(x: 0, y: centerY))
            topPath.move(to: CGPoint(x: 0, y: centerY))
            
            // Limit drawing range to current time
            let displayEndTime = min(currentTime, totalDuration)
            let displayEndPixel = CGFloat(displayEndTime / totalDuration) * width
            
            // Set appropriate number of points to draw
            let intervals = min(1000, Int(displayEndPixel)) // Adjust point count based on visible range
            
            // Don't draw if visible range is 0
            guard intervals > 0 else { return }
            
            let timeStep = displayEndTime / Double(intervals)
            
            // Draw only waveform up to current time
            for i in 0...intervals {
                // Time position for this point
                let timePosition = Double(i) * timeStep
                // Calculate X coordinate from time
                let x = timePosition * Double(pixelsPerSecond)
                
                // Sample index corresponding to this time position
                let sampleIndex = Int(timePosition * estimatedSampleRate)
                
                // Check if within sample range
                if sampleIndex < samples.count {
                    let sampleValue = samples[sampleIndex]
                    let scaledSample = CGFloat(sampleValue) * CGFloat(scaleFactor)
                    
                    // Waveform top part
                    let topY = centerY - min(0.95, max(-0.95, scaledSample)) * maxAmplitude
                    
                    path.addLine(to: CGPoint(x: CGFloat(x), y: topY))
                    topPath.addLine(to: CGPoint(x: CGFloat(x), y: topY))
                    
                    // Connect to bottom at the last point
                    if i == intervals {
                        path.addLine(to: CGPoint(x: CGFloat(x), y: centerY))
                    }
                }
            }
            
            // Draw bottom part (mirror) of waveform also up to current time
            for i in stride(from: intervals, through: 0, by: -1) {
                let timePosition = Double(i) * timeStep
                let x = timePosition * Double(pixelsPerSecond)
                let sampleIndex = Int(timePosition * estimatedSampleRate)
                
                if sampleIndex < samples.count {
                    let sampleValue = samples[sampleIndex]
                    let scaledSample = CGFloat(sampleValue) * CGFloat(scaleFactor)
                    let y = centerY + min(0.95, max(-0.95, scaledSample)) * maxAmplitude * 0.8
                    
                    path.addLine(to: CGPoint(x: CGFloat(x), y: y))
                }
            }
            
            path.closeSubpath()
            
            // Gradient fill
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
            
            // Highlight top line of waveform
            context.stroke(topPath, with: .color(.blue.opacity(0.9)), lineWidth: 1.5)
        }
        .frame(width: width, height: height)
    }
}

// Playhead view
struct TimelinePlayheadView: View {
    let currentPosition: TimeInterval
    let totalDuration: TimeInterval
    let width: CGFloat
    let height: CGFloat
    
    var body: some View {
        GeometryReader { geometry in
            let x = min((currentPosition / totalDuration) * width, width)
            
            // Vertical line
            Rectangle()
                .fill(Color.red)
                .frame(width: 1.5)
                .frame(height: height)
                .position(x: x, y: height / 2)
            
            // Current position display
            Text(formatCurrentPosition(currentPosition))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.red)
                .cornerRadius(3)
                .position(x: x, y: 10)
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