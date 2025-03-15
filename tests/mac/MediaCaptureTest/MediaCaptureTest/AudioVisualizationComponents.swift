import SwiftUI

// 音声関連の視覚化コンポーネントをまとめたファイル

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
    var highLightPosition: CGFloat? = nil
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 波形の背景
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
                
                // 波形のエッジライン
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
                
                // 再生位置インジケーター（存在する場合）
                if let position = highLightPosition {
                    Rectangle()
                        .fill(Color.red.opacity(0.8))
                        .frame(width: 2)
                        .position(x: position * geometry.size.width, y: geometry.size.height / 2)
                }
            }
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