import SwiftUI
import ScreenCaptureKit

struct FrameRateTestView: View {
    @StateObject private var viewModel = FrameRateTestViewModel()
    @State private var selectedTest: Int = 0
    
    // テスト情報定義
    let testOptions = ["フレームレート精度テスト", "低フレームレートテスト", "オーディオのみモードテスト", 
                   "異なるフレームレートテスト", "極端なフレームレートテスト", "長時間キャプチャテスト",
                   "メディアデータフォーマットテスト", "画像フォーマットオプションテスト"]
    
    // 各テストの説明と推奨パラメータ
    let testDescriptions: [String: (purpose: String, params: String)] = [
        "フレームレート精度テスト": (
            "指定されたフレームレートで実際にビデオフレームが配信される精度と音声データの連続性を検証します。",
            "framesToCapture: 5-10フレーム\ntargetFrameRate: 15-30fps\nallowedFrameRateError: 30%"
        ),
        "低フレームレートテスト": (
            "フレームレートが1fps未満の極端に低い状況でのシステムの動作を確認します。",
            "lowFrameRate: 0.5fps（2秒に1フレーム）\nframesToCapture: 3フレーム"
        ),
        "オーディオのみモードテスト": (
            "フレームレート0（ビデオなし）での動作を検証します。ビデオフレームが送られず、音声データのみが継続的に配信されることを確認します。",
            "特別な設定は不要です（内部でフレームレート0を使用）"
        ),
        "異なるフレームレートテスト": (
            "様々なフレームレート（30fps、15fps、5fps）での動作の一貫性を検証します。各設定での精度と性能を比較します。",
            "特別な設定は不要です（内部で複数のフレームレートを自動テスト）"
        ),
        "極端なフレームレートテスト": (
            "非常に低い（0.5fps）または高い（60fps、120fps）フレームレートでの限界性能を検証します。システムの安定性と処理能力を評価します。",
            "特別な設定は不要です（内部で極端な値を自動テスト）"
        ),
        "長時間キャプチャテスト": (
            "長時間キャプチャ時の安定性とリソース使用状況を検証します。時間経過による性能低下やエラー発生がないか確認します。",
            "testDuration: 8-30秒（実運用テストなら長めの時間を設定）\ntargetFrameRate: 15fps（標準値）"
        ),
         "メディアデータフォーマットテスト": (
            "キャプチャされたメディアデータのフォーマットとメタデータが正しいことを検証します。ビデオとオーディオの両方のデータ構造をチェックします。",
            "特別なパラメータは不要です（標準設定で実行）"
        ),
        "画像フォーマットオプションテスト": (
            "異なる画像フォーマット（JPEG高品質、JPEG低品質、RAW）でのキャプチャをテストし、設定通りのフォーマットでデータが取得できるか検証します。",
            "特別なパラメータは不要です（内部で複数のフォーマットを自動テスト）"
        )
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                Text("フレームレート実機テスト")
                    .font(.headline)
                Spacer()
                Button("ターゲット更新") {
                    viewModel.loadAvailableTargets()
                }
            }
            .padding()
            .background(Color(.windowBackgroundColor).opacity(0.5))
            
            // メインコンテンツ
            HStack(spacing: 0) {
                // 左パネル - テスト設定
                VStack(alignment: .leading, spacing: 16) {
                    // テスト対象選択
                    VStack(alignment: .leading) {
                        Text("キャプチャ対象")
                            .font(.headline)
                        
                        if viewModel.availableTargets.isEmpty {
                            Text("キャプチャ対象が利用できません")
                                .foregroundColor(.red)
                        } else {
                            Picker("キャプチャ対象", selection: $viewModel.selectedTargetIndex) {
                                ForEach(0..<viewModel.availableTargets.count, id: \.self) { index in
                                    Text(getTargetDisplayName(viewModel.availableTargets[index])).tag(index)
                                }
                            }
                        }
                    }
                    
                    Divider()
                    
                    // テストパラメータ設定
                    VStack(alignment: .leading) {
                        Text("テストパラメータ")
                            .font(.headline)
                        
                        HStack {
                            Text("フレーム数:")
                            TextField("", value: $viewModel.framesToCapture, format: .number)
                                .frame(width: 60)
                            Stepper("", value: $viewModel.framesToCapture, in: 3...20)
                        }
                        
                        HStack {
                            Text("フレームレート:")
                            TextField("", value: $viewModel.targetFrameRate, format: .number)
                                .frame(width: 60)
                            Stepper("", value: $viewModel.targetFrameRate, in: 1...60, step: 5)
                        }
                        
                        HStack {
                            Text("許容誤差:")
                            TextField("", value: $viewModel.allowedFrameRateError, format: .number)
                                .frame(width: 60)
                            Stepper("", value: $viewModel.allowedFrameRateError, in: 0.1...0.5, step: 0.05)
                            Text("\(Int(viewModel.allowedFrameRateError * 100))%")
                        }
                        
                        HStack {
                            Text("低フレームレート:")
                            TextField("", value: $viewModel.lowFrameRate, format: .number)
                                .frame(width: 60)
                            Stepper("", value: $viewModel.lowFrameRate, in: 0.1...1, step: 0.1)
                            Text("\(String(format: "%.1f", 1.0/viewModel.lowFrameRate))秒毎")
                        }
                        
                        HStack {
                            Text("テスト時間:")
                            TextField("", value: $viewModel.testDuration, format: .number)
                                .frame(width: 60)
                            Stepper("", value: $viewModel.testDuration, in: 3...30)
                            Text("秒")
                        }
                    }
                    
                    Divider()
                    
                    // テスト選択と実行
                    VStack(alignment: .leading) {
                        Text("テスト実行")
                            .font(.headline)
                        
                        Picker("テスト種類", selection: $selectedTest) {
                            ForEach(0..<testOptions.count, id: \.self) { index in
                                Text(testOptions[index]).tag(index)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: selectedTest) { newValue in
                            // 選択されたテストに基づいてパラメータ推奨値を設定
                            updateRecommendedParameters(for: newValue)
                        }
                        
                        // 選択されたテストの説明を表示
                        if let selectedTestName = selectedTest < testOptions.count ? testOptions[selectedTest] : nil,
                           let testInfo = testDescriptions[selectedTestName] {
                            
                            VStack(alignment: .leading, spacing: 8) {
                                // テスト目的
                                Group {
                                    Text("目的:")
                                        .font(.subheadline.bold())
                                    Text(testInfo.purpose)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                // 推奨パラメータ
                                Group {
                                    Text("推奨設定:")
                                        .font(.subheadline.bold())
                                    Text(testInfo.params)
                                        .font(.caption.monospaced())
                                        .foregroundColor(.blue)
                                }
                            }
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.controlBackgroundColor).opacity(0.5))
                            .cornerRadius(4)
                            .padding(.vertical, 2)
                        }
                        
                        HStack {
                            Button("テスト実行") {
                                Task {
                                    await runSelectedTest()
                                }
                            }
                            .disabled(viewModel.isRunningTest || viewModel.selectedTarget == nil)
                            
                            Button("結果クリア") {
                                viewModel.clearResults()
                            }
                            
                            Toggle("ログ記録", isOn: $viewModel.enableLogging)
                        }
                    }
                    
                    if viewModel.isRunningTest {
                        VStack(alignment: .leading) {
                            Text(viewModel.currentTest)
                            ProgressView(value: viewModel.progressValue)
                            Text(viewModel.testStatus)
                                .font(.caption)
                        }
                    }
                    
                    Spacer()
                }
                .padding()
                .frame(width: 300)
                .background(Color(.windowBackgroundColor).opacity(0.3))
                
                Divider()
                
                // 右パネル - 結果表示
                VStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(viewModel.testResults, id: \.self) { result in
                                resultView(for: result)
                            }
                        }
                        .padding()
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            viewModel.loadAvailableTargets()
        }
    }
    
    func resultView(for result: String) -> some View {
        HStack(alignment: .top) {
            if result.contains("====") {
                Text(result)
                    .font(.headline)
            } else if result.contains("✅") {
                Text(result)
                    .foregroundColor(.green)
            } else if result.contains("⚠️") {
                Text(result)
                    .foregroundColor(.orange)
            } else if result.contains("❌") {
                Text(result)
                    .foregroundColor(.red)
            } else {
                Text(result)
                    .font(.callout)
            }
        }
    }
    
    private func getTargetDisplayName(_ target: MediaCaptureTarget) -> String {
        if target.displayID > 0 {
            return "画面: \(target.title ?? "Display \(target.displayID)")"
        } else {
            if let appName = target.applicationName, !appName.isEmpty {
                return "ウィンドウ: \(appName) - \(target.title ?? "無題")"
            } else {
                return "ウィンドウ: \(target.title ?? "無題")"
            }
        }
    }
    
    private func runSelectedTest() async {
        guard viewModel.selectedTarget != nil else {
            viewModel.logMessage("エラー: テスト対象が選択されていません")
            return
        }
        
        switch selectedTest {
        case 0:
            await viewModel.runFrameRateAccuracyTest()
        case 1:
            await viewModel.runLowFrameRateTest()  // 修正：テスト2を実行
        case 2:
            await viewModel.runAudioOnlyModeTest()  // 修正：テスト3を実行
        case 3:
            await viewModel.runDifferentFrameRatesTest()
        case 4:
            await viewModel.runExtremeFrameRatesTest()
        case 5:
            await viewModel.runExtendedCaptureTest()
        case 6:
            await viewModel.runMediaDataFormatTest()
        case 7:
            await viewModel.runImageFormatOptionsTest()
        default:
            viewModel.logMessage("不明なテストです")
        }
    }
    
    // 推奨パラメータを更新するメソッドを追加
    private func updateRecommendedParameters(for testIndex: Int) {
        guard testIndex < testOptions.count else { return }
        
        // 選択されたテストに基づいて推奨パラメータを設定
        switch testIndex {
        case 0: // フレームレート精度テスト
            viewModel.framesToCapture = 5
            viewModel.targetFrameRate = 15.0
            viewModel.allowedFrameRateError = 0.3
        case 1: // 低フレームレートテスト
            viewModel.framesToCapture = 3
            viewModel.lowFrameRate = 0.5
        case 5: // 長時間キャプチャテスト
            viewModel.testDuration = 8.0
            viewModel.targetFrameRate = 15.0
        default:
            break // その他のテストは自動設定不要
        }
    }
}

#Preview {
    FrameRateTestView()
}
