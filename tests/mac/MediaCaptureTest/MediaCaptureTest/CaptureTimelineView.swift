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
    @State private var isAutoScrolling = true
    
    var body: some View {
        VStack(spacing: 0) {
            // 制御バー
            HStack {
                // タイムライン制御ボタン
                Button(action: {
                    viewModel.toggleTimelineCapturing(!viewModel.isTimelineCapturingEnabled)
                }) {
                    Image(systemName: viewModel.isTimelineCapturingEnabled ? "stop.circle.fill" : "record.circle")
                        .foregroundColor(viewModel.isTimelineCapturingEnabled ? .red : .primary)
                }
                .help(viewModel.isTimelineCapturingEnabled ? "タイムライン記録を停止" : "タイムライン記録を開始")
                .buttonStyle(.borderless)
                .font(.title)
                
                // 自動スクロールトグル
                Toggle(isOn: $isAutoScrolling) {
                    Text("自動スクロール")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                
                Spacer()
                
                // タイムライン情報
                Text("タイムライン: \(formatTimeCode(viewModel.timelineCurrentPosition)) / \(formatTimeCode(viewModel.timelineTotalDuration))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                // ズームコントロール
                Button(action: {
                    withAnimation { viewModel.timelineZoomLevel = max(0.5, viewModel.timelineZoomLevel - 0.5) }
                }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(viewModel.timelineZoomLevel <= 0.5)
                .buttonStyle(.borderless)
                
                Text("ズーム: \(Int(viewModel.timelineZoomLevel * 100))%")
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
            
            // メインタイムラインエリア
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
                        // 自動スクロールが有効な場合のみスクロール
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
    
    // 拡大レベルに基づいたタイムライン幅を計算
    private func calculateTimelineWidth(for geometry: GeometryProxy) -> CGFloat {
        let baseWidth = max(geometry.size.width, 800)
        return baseWidth * CGFloat(viewModel.timelineZoomLevel)
    }
    
    // 時間を MM:SS.ms 形式でフォーマット
    private func formatTimeCode(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let milliseconds = Int((time.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%01d", minutes, seconds, milliseconds)
    }
}

// タイムライン全体を統合した表示
struct UnifiedTimelineView: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    let width: CGFloat
    let height: CGFloat
    @State private var isDragging = false
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            // 背景グリッド
            TimelineGridView(
                totalDuration: viewModel.timelineTotalDuration,
                width: width,
                height: height
            )
            
            // メインコンテンツ
            VStack(spacing: 0) {
                // サムネイルエリア
                ZStack(alignment: .topLeading) {
                    // サムネイル背景
                    Rectangle()
                        .fill(Color.black.opacity(0.05))
                        .frame(height: height * 0.4)
                    
                    // サムネイル配置
                    ForEach(viewModel.timelineThumbnails) { thumbnail in
                        ZStack(alignment: .bottomLeading) { // .bottomから.bottomLeftに変更
                            // タイムスタンプ位置を示すマーカー線
                            Rectangle()
                                .fill(Color.gray.opacity(0.5))
                                .frame(width: 1, height: height * 0.1)
                                .offset(y: -5)
                            
                            ThumbnailView(thumbnail: thumbnail)
                                .frame(width: thumbnailWidth)
                                // オフセットを削除（左端揃えにするため）
                                // .offset(x: -thumbnailWidth/2) の行を削除
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
                
                // 波形エリア
                ZStack(alignment: .topLeading) {
                    // 波形背景
                    Rectangle()
                        .fill(Color.black.opacity(0.02))
                        .frame(height: height * 0.6)
                    
                    // 波形表示
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
            
            // 再生ヘッド表示
            TimelinePlayheadView(
                currentPosition: viewModel.timelineCurrentPosition,
                totalDuration: viewModel.timelineTotalDuration,
                width: width,
                height: height
            )
            
            // スクラブ用の透明オーバーレイ
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: width, height: height)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            // タイムラインの再生中なら一時停止
                            if viewModel.isPlaying {
                                viewModel.stopPlayback()
                            }
                            
                            // ドラッグ位置から時間を計算
                            let newPosition = timeForPosition(value.location.x)
                            viewModel.timelineCurrentPosition = newPosition
                            
                            // プレビュー画像を更新
                            viewModel.updatePreviewImageForPosition(newPosition)
                        }
                        .onEnded { value in
                            // ドラッグ終了時の位置から時間を計算
                            let position = timeForPosition(value.location.x)
                            
                            // その位置から再生開始
                            if !viewModel.isCapturing {
                                viewModel.playFromPosition(position)
                            }
                            isDragging = false
                        }
                )
        }
        .frame(width: width, height: height)
        .overlay(
            // 再生コントロールオーバーレイ
            VStack {
                Spacer()
                HStack {
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
                    } else if !viewModel.isCapturing && !viewModel.timelineThumbnails.isEmpty {
                        Button(action: {
                            viewModel.playFromPosition(viewModel.timelineCurrentPosition)
                        }) {
                            Image(systemName: "play.fill")
                                .font(.title)
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Circle().fill(Color.blue))
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Spacer()
                    
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
    
    // サムネイルの幅
    private var thumbnailWidth: CGFloat { 120 }
    
    // 時間から位置へ変換
    private func positionForTime(_ time: TimeInterval) -> CGFloat {
        return (time / viewModel.timelineTotalDuration) * width
    }
    
    // 位置から時間へ変換
    private func timeForPosition(_ x: CGFloat) -> TimeInterval {
        let normalized = max(0, min(1, x / width))
        return normalized * viewModel.timelineTotalDuration
    }
    
    // 時間を MM:SS.ms 形式でフォーマット
    private func formatTimeCode(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let milliseconds = Int((time.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%01d", minutes, seconds, milliseconds)
    }
}

// タイムライングリッド
struct TimelineGridView: View {
    let totalDuration: TimeInterval
    let width: CGFloat
    let height: CGFloat
    
    var body: some View {
        Canvas { context, size in
            // 垂直の時間マーカーを計算
            let secondWidth = width / CGFloat(totalDuration)
            
            // 間隔を計算 (ズームレベルに応じて)
            let secondsPerMark: Int
            if secondWidth < 5 {
                secondsPerMark = 60  // 1分間隔
            } else if secondWidth < 15 {
                secondsPerMark = 30  // 30秒間隔
            } else if secondWidth < 30 {
                secondsPerMark = 10  // 10秒間隔
            } else {
                secondsPerMark = 5   // 5秒間隔
            }
            
            let markerCount = Int(totalDuration) / secondsPerMark + 1
            
            // 時間マーカーを描画
            for i in 0...markerCount {
                let seconds = i * secondsPerMark
                let x = CGFloat(seconds) * secondWidth
                
                // 幅を超えるマーカーは描画しない
                if x > width {
                    break
                }
                
                // 垂直線を描画
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: height))
                
                context.stroke(path, with: .color(.gray.opacity(0.2)), lineWidth: 1)
                
                // 時間テキストを描画
                let minutes = seconds / 60
                let remainingSeconds = seconds % 60
                let timeString = String(format: "%d:%02d", minutes, remainingSeconds)
                
                let text = Text(timeString)
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                
                context.draw(text, at: CGPoint(x: x + 4, y: 4))
            }
            
            // 波形エリアの水平レベルライン
            let waveformTop = size.height * 0.4
            let waveformHeight = size.height * 0.6
            let waveformCenter = waveformTop + waveformHeight / 2
            
            // 中央線（ゼロレベル）
            var centerPath = Path()
            centerPath.move(to: CGPoint(x: 0, y: waveformCenter))
            centerPath.addLine(to: CGPoint(x: width, y: waveformCenter))
            context.stroke(centerPath, with: .color(.gray.opacity(0.4)), lineWidth: 1)
            
            // レベルガイドライン
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

// サムネイル表示
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
                    // 画像の左端下部に時間位置を示すマーカー
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 2, height: 5)
                        .offset(y: 35),
                    alignment: .bottomLeading // .bottomから.bottomLeadingに変更
                )
            
            Text(formatTimestamp(thumbnail.timestamp))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(2)
                .background(Color.white.opacity(0.7))
                .cornerRadius(2)
                .frame(maxWidth: .infinity, alignment: .leading) // 左揃えに変更
        }
    }
    
    private func formatTimestamp(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct ImprovedWaveformView: View {
    let samples: [Float]
    let currentTime: TimeInterval
    let totalDuration: TimeInterval
    let width: CGFloat
    let height: CGFloat
    
    var body: some View {
        Canvas { context, size in
            // サンプルがなければ描画しない
            guard !samples.isEmpty, totalDuration > 0 else { return }
            
            let centerY = size.height / 2
            
            // 波形スケーリングの設定
            let maxAmplitude = centerY * 0.4
            let maxSampleValue = samples.map { abs($0) }.max() ?? 1.0
            let scaleFactor: Float = maxSampleValue > 0.3 ? min(1.0, 0.6 / maxSampleValue) : 2.0
            
            // 時間とピクセルの変換係数
            let pixelsPerSecond = width / CGFloat(totalDuration)
            
            // サンプルレート推定（サンプル数÷現在時間）- totalDurationではなくcurrentTimeを使用
            // サンプルは現在時間までしか存在しないはず
            let effectiveDuration = min(currentTime, totalDuration)
            let estimatedSampleRate = samples.count > 0 ? Double(samples.count) / effectiveDuration : 44100.0
            
            // 描画パス
            var path = Path()
            var topPath = Path()
            
            // 最初の点を設定
            path.move(to: CGPoint(x: 0, y: centerY))
            topPath.move(to: CGPoint(x: 0, y: centerY))
            
            // 現在時間までのみを表示するため、描画範囲を制限
            let displayEndTime = min(currentTime, totalDuration)
            let displayEndPixel = CGFloat(displayEndTime / totalDuration) * width
            
            // 描画するポイント数を適切に設定
            let intervals = min(1000, Int(displayEndPixel)) // 表示範囲に応じたポイント数
            
            // 表示範囲が0なら何も描画しない
            guard intervals > 0 else { return }
            
            let timeStep = displayEndTime / Double(intervals)
            
            // 現在時間までの波形のみを描画
            for i in 0...intervals {
                // この点の時間位置
                let timePosition = Double(i) * timeStep
                // 時間位置からX座標を計算
                let x = timePosition * Double(pixelsPerSecond)
                
                // 時間位置に対応するサンプルインデックス
                let sampleIndex = Int(timePosition * estimatedSampleRate)
                
                // サンプル範囲内か確認
                if sampleIndex < samples.count {
                    let sampleValue = samples[sampleIndex]
                    let scaledSample = CGFloat(sampleValue) * CGFloat(scaleFactor)
                    
                    // 波形の上部
                    let topY = centerY - min(0.95, max(-0.95, scaledSample)) * maxAmplitude
                    
                    path.addLine(to: CGPoint(x: CGFloat(x), y: topY))
                    topPath.addLine(to: CGPoint(x: CGFloat(x), y: topY))
                    
                    // 最後の点で下部につなぐ
                    if i == intervals {
                        path.addLine(to: CGPoint(x: CGFloat(x), y: centerY))
                    }
                }
            }
            
            // 波形の下部（ミラー）も現在時間までのみ描画
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
            
            // グラデーション塗りつぶし
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
            
            // 波形の上部ラインを強調表示
            context.stroke(topPath, with: .color(.blue.opacity(0.9)), lineWidth: 1.5)
        }
        .frame(width: width, height: height)
    }
}

// 再生ヘッド
struct TimelinePlayheadView: View {
    let currentPosition: TimeInterval
    let totalDuration: TimeInterval
    let width: CGFloat
    let height: CGFloat
    
    var body: some View {
        GeometryReader { geometry in
            let x = min((currentPosition / totalDuration) * width, width)
            
            // 垂直線
            Rectangle()
                .fill(Color.red)
                .frame(width: 1.5)
                .frame(height: height)
                .position(x: x, y: height / 2)
            
            // 現在位置表示
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