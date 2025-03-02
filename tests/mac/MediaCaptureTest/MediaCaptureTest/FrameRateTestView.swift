import SwiftUI
import Charts

struct FrameRateTestView: View {
    @ObservedObject var viewModel: MediaCaptureViewModel
    @StateObject private var testVM: PerformanceTestViewModel
    
    init(viewModel: MediaCaptureViewModel) {
        self.viewModel = viewModel
        // State初期化でPerformanceTestViewModelを作成
        _testVM = StateObject(wrappedValue: PerformanceTestViewModel(captureViewModel: viewModel))
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // 設定部分
            GroupBox("テスト設定") {
                VStack(spacing: 10) {
                    // フレームレート選択
                    HStack {
                        Text("目標フレームレート:")
                        Slider(
                            value: $testVM.selectedTestFrameRate,
                            in: 0.1...60.0,
                            step: 0.1
                        )
                        .disabled(testVM.isPerformanceTesting)
                        
                        Text("\(testVM.selectedTestFrameRate, specifier: "%.1f") FPS")
                            .frame(width: 60, alignment: .trailing)
                            .monospacedDigit()
                    }

                    // 継続時間選択
                    HStack {
                        Text("テスト継続時間:")
                        Slider(
                            value: $testVM.testDuration,
                            in: 1.0...60.0,
                            step: 1.0
                        )
                        .disabled(testVM.isPerformanceTesting)
                        
                        Text("\(Int(testVM.testDuration))秒")
                            .frame(width: 60, alignment: .trailing)
                    }

                    // スタート/ストップボタン
                    HStack {
                        Button(action: {
                            Task {
                                await testVM.startPerformanceTest()
                            }
                        }) {
                            Text("テスト開始")
                        }
                        .disabled(testVM.isPerformanceTesting)
                        
                        Button(action: {
                            Task {
                                await testVM.stopPerformanceTest()
                            }
                        }) {
                            Text("停止")
                        }
                        .disabled(!testVM.isPerformanceTesting)
                        
                        if testVM.isPerformanceTesting {
                            ProgressView()
                                .scaleEffect(0.6)
                                .padding(.leading, 5)
                            
                            Text("\(testVM.testElapsedTime, specifier: "%.1f")秒 / \(Int(testVM.testDuration))秒")
                                .font(.caption)
                        }
                        
                        Spacer()
                    }
                }
            }
            
            // 結果表示部分
            if testVM.hasTestResults {
                GroupBox("テスト結果") {
                    VStack(alignment: .leading, spacing: 8) {
                        // 結果サマリー
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("目標: \(String(format: "%.1f", testVM.selectedTestFrameRate)) FPS (間隔: \(String(format: "%.4f", 1.0/testVM.selectedTestFrameRate))秒)")
                                Text("実測: \(String(format: "%.2f", testVM.measuredFPS)) FPS (精度: \(String(format: "%.1f", testVM.fpsAccuracy * 100))%)")
                                Text("フレーム数: \(testVM.frameTimestamps.count)個 (\(String(format: "%.1f", testVM.testElapsedTime))秒間)")
                                if (!testVM.frameDeltas.isEmpty) {
                                    Text("平均間隔: \(String(format: "%.4f", testVM.frameDeltas.reduce(0, +) / Double(testVM.frameDeltas.count)))秒")
                                    Text("最小間隔: \(String(format: "%.4f", testVM.frameDeltas.min() ?? 0))秒")
                                    Text("最大間隔: \(String(format: "%.4f", testVM.frameDeltas.max() ?? 0))秒")
                                }
                            }
                            
                            Spacer()
                            
                            VStack {
                                Button("結果をコピー") {
                                    testVM.copyTestResultsToClipboard()
                                }
                                .disabled(testVM.frameDeltas.isEmpty)
                            }
                        }
                        
                        Divider()
                        
                        // フレーム間隔のチャート
                        Text("フレーム間隔グラフ")
                            .font(.headline)
                        
                        FrameIntervalChartView(viewModel: testVM)
                            .frame(height: 180)
                        
                        // 問題の検出
                        if let message = testVM.testResultMessage, !message.isEmpty {
                            GroupBox {
                                VStack(alignment: .leading) {
                                    Text("検出された問題:")
                                        .font(.headline)
                                        .foregroundStyle(testVM.testResultSuccess ? .green : .red)
                                    Text(message)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                // 音声データ情報セクション
                if testVM.hasAudioData {
                    GroupBox("音声データ情報") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("サンプルレート: \(Int(testVM.audioSampleRate)) Hz")
                            Text("チャンネル数: \(testVM.audioChannelCount)")
                            Text("音声バッファ処理数: \(testVM.audioBuffersProcessed)")
                            
                            if testVM.audioLatencyStats.count > 0 {
                                Divider()
                                Text("音声処理レイテンシ:")
                                    .font(.headline)
                                HStack(spacing: 12) {
                                    Text("平均: \(String(format: "%.2f", testVM.audioLatencyStats.reduce(0.0, +) / Double(testVM.audioLatencyStats.count))) ms")
                                    Text("最小: \(String(format: "%.2f", testVM.audioLatencyStats.min() ?? 0)) ms")
                                    Text("最大: \(String(format: "%.2f", testVM.audioLatencyStats.max() ?? 0)) ms")
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding()
    }
}

// フレーム間隔チャートビュー
struct FrameIntervalChartView: View {
    @ObservedObject var viewModel: PerformanceTestViewModel
    
    var body: some View {
        if #available(macOS 13.0, *) {
            Chart {
                ForEach(Array(viewModel.frameDeltas.enumerated()), id: \.0) { index, delta in
                    LineMark(
                        x: .value("フレーム", index + 2),
                        y: .value("間隔(秒)", delta)
                    )
                    .foregroundStyle(.blue)
                }
                
                if !viewModel.frameDeltas.isEmpty {
                    RuleMark(y: .value("目標間隔", 1.0 / viewModel.selectedTestFrameRate))
                        .foregroundStyle(.red)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
                        
                    if let avgDelta = viewModel.frameDeltas.isEmpty ? nil : 
                        viewModel.frameDeltas.reduce(0, +) / Double(viewModel.frameDeltas.count) {
                        RuleMark(y: .value("平均間隔", avgDelta))
                            .foregroundStyle(.green)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
            }
            .chartYScale(domain: getChartYDomain())
        } else {
            Text("グラフ表示にはmacOS 13.0以上が必要です")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.gray.opacity(0.1))
        }
    }
    
    // チャートのY軸範囲を計算
    func getChartYDomain() -> ClosedRange<Double> {
        if viewModel.frameDeltas.isEmpty {
            return 0...1
        }
        
        let targetInterval = 1.0 / viewModel.selectedTestFrameRate
        let minVal = viewModel.frameDeltas.min() ?? 0
        let maxVal = viewModel.frameDeltas.max() ?? 1
        
        let minValue = min(minVal, targetInterval * 0.5)
        let maxValue = max(maxVal, targetInterval * 1.5)
        
        return minValue...maxValue
    }
}
