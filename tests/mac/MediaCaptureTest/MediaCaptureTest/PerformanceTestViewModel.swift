import Foundation
import SwiftUI
import Combine
import AVFoundation
import ScreenCaptureKit

// パフォーマンステスト専用のViewModel
@MainActor
class PerformanceTestViewModel: ObservableObject {
    // メインのViewModelへの参照（弱参照）
    private weak var captureViewModel: MediaCaptureViewModel?
    
    // 性能テスト関連の状態変数
    @Published var isPerformanceTesting = false
    @Published var isTestRunning = false
    @Published var selectedTestFrameRate: Double = 30.0
    @Published var testDuration: Double = 10.0
    @Published var frameTimestamps: [Double] = []
    @Published var frameDeltas: [Double] = []
    @Published var measuredFPS: Double = 0.0
    @Published var fpsAccuracy: Double = 0.0
    @Published var testStartTime: Double = 0.0
    @Published var testElapsedTime: Double = 0.0
    @Published var hasTestResults = false
    @Published var showDetailedFrameTimes = false
    @Published var testResultMessage: String? = nil
    @Published var testResultSuccess = false
    
    // 音声関連のプロパティを追加
    @Published var hasAudioData: Bool = false
    @Published var audioBuffersProcessed: Int = 0
    @Published var audioLatencyStats: [Double] = []
    @Published var audioSampleRate: Double = 0.0
    @Published var audioChannelCount: Int = 0
    
    // キャプチャー関連
    private var mediaCapture = MediaCapture()
    
    // 初期化
    init(captureViewModel: MediaCaptureViewModel) {
        self.captureViewModel = captureViewModel
        
        // 性能テスト関連の初期値
        selectedTestFrameRate = 30.0
        testDuration = 10.0
    }
    
    // テスト開始メソッド
    func startPerformanceTest() async {
        // 既存のキャプチャが動作中なら停止
        if captureViewModel?.isCapturing ?? false {
            await captureViewModel?.stopCapture()
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms待機
        }
        
        // テスト状態の初期化
        frameTimestamps = []
        frameDeltas = []
        measuredFPS = 0.0
        fpsAccuracy = 0.0
        testResultMessage = nil
        testStartTime = Date().timeIntervalSince1970
        isPerformanceTesting = true
        hasTestResults = false
        audioBuffersProcessed = 0
        audioLatencyStats = []
        hasAudioData = false
        
        guard let viewModel = captureViewModel,
              viewModel.selectedTargetIndex < viewModel.filteredTargets.count else {
            testResultMessage = "キャプチャ対象が選択されていません"
            testResultSuccess = false
            isPerformanceTesting = false
            return
        }
        
        let target = viewModel.filteredTargets[viewModel.selectedTargetIndex]
        
        // 性能テスト用のメディアハンドラ
        let perfTestHandler: (StreamableMediaData) -> Void = { [weak self] media in
            guard let self = self else { return }
            
            let now = Date().timeIntervalSince1970
            
            // 音声バッファの処理
            if let audioInfo = media.metadata.audioInfo {
                Task { @MainActor in
                    self.audioSampleRate = audioInfo.sampleRate
                    self.audioChannelCount = audioInfo.channelCount
                    
                    if let _ = media.audioBuffer {
                        self.audioBuffersProcessed += 1
                        self.hasAudioData = true
                        
                        // 音声レイテンシの計算（ミリ秒）
                        let latency = (now - media.metadata.timestamp) * 1000
                        self.audioLatencyStats.append(latency)
                    }
                }
            }
            
            // ビデオフレームの処理
            if let _ = media.videoBuffer {
                let relativeTime = now - self.testStartTime
                
                // フレームタイムスタンプを記録
                Task { @MainActor in
                    self.frameTimestamps.append(relativeTime)
                    
                    // フレーム間隔を計算
                    if self.frameTimestamps.count > 1 {
                        let lastIndex = self.frameTimestamps.count - 1
                        let delta = self.frameTimestamps[lastIndex] - self.frameTimestamps[lastIndex - 1]
                        self.frameDeltas.append(delta)
                    }
                    
                    // 経過時間の更新
                    self.testElapsedTime = relativeTime
                    
                    // 測定FPSとフレームレート精度の計算
                    if self.frameTimestamps.count > 1 {
                        let duration = self.frameTimestamps.last! - self.frameTimestamps.first!
                        self.measuredFPS = Double(self.frameTimestamps.count - 1) / duration
                        self.fpsAccuracy = self.measuredFPS / self.selectedTestFrameRate
                    }
                }
            }
            
            // メインVMのハンドラも呼び出し（画面表示など）
            if let viewModel = self.captureViewModel {
                viewModel.handleMediaData(media)
            }
            
            // テスト時間が経過したら自動的に停止
            let relativeTime = now - self.testStartTime
            if relativeTime >= self.testDuration {
                Task { await self.stopPerformanceTest() }
            }
        }
        
        // キャプチャ開始
        do {
            let quality: MediaCapture.CaptureQuality = .high
            
            _ = try await mediaCapture.startCapture(
                target: target,
                mediaHandler: perfTestHandler,
                errorHandler: { [weak self] error in
                    Task { @MainActor in
                        self?.testResultMessage = "キャプチャエラー: \(error)"
                    }
                },
                framesPerSecond: selectedTestFrameRate,
                quality: quality
            )
            
            print("性能テスト開始: \(selectedTestFrameRate) FPS")
            
        } catch {
            isPerformanceTesting = false
            testResultMessage = "テスト開始エラー: \(error.localizedDescription)"
            testResultSuccess = false
            print("テスト開始エラー: \(error)")
        }
    }
    
    // テスト停止メソッド
    func stopPerformanceTest() async {
        // キャプチャ停止
        await mediaCapture.stopCapture()
        
        isPerformanceTesting = false
        hasTestResults = frameTimestamps.count > 1
        
        // 最終結果の確定
        if hasTestResults {
            let duration = frameTimestamps.last! - frameTimestamps.first!
            measuredFPS = Double(frameTimestamps.count - 1) / duration
            fpsAccuracy = measuredFPS / selectedTestFrameRate
            
            let isGoodAccuracy = fpsAccuracy > 0.9 && fpsAccuracy < 1.1
            testResultMessage = "テスト完了: FPS精度 \(String(format: "%.1f%%", fpsAccuracy * 100))"
            testResultSuccess = isGoodAccuracy
            
            print("テスト結果:")
            print("- 目標FPS: \(selectedTestFrameRate)")
            print("- 測定FPS: \(measuredFPS)")
            print("- 精度: \(fpsAccuracy * 100)%")
            print("- フレーム数: \(frameTimestamps.count)")
            
            // フレーム間隔の統計
            if let minDelta = frameDeltas.min(), let maxDelta = frameDeltas.max() {
                let avgDelta = frameDeltas.reduce(0, +) / Double(frameDeltas.count)
                print("- 平均フレーム間隔: \(avgDelta)秒")
                print("- 最小フレーム間隔: \(minDelta)秒")
                print("- 最大フレーム間隔: \(maxDelta)秒")
            }
        }
    }
    
    // テスト結果クリア
    func clearTestResults() {
        frameTimestamps = []
        frameDeltas = []
        measuredFPS = 0.0
        fpsAccuracy = 0.0
        testElapsedTime = 0.0
        hasTestResults = false
        testResultMessage = nil
    }
    
    // テスト結果をCSVに保存
    func saveTestResultsToCSV() {
        guard hasTestResults else { return }
        
        var csvContent = "フレーム番号,相対時間(秒),フレーム間隔(秒)\n"
        
        for i in 0..<frameTimestamps.count {
            if i == 0 {
                csvContent += "\(i+1),\(frameTimestamps[i]),\n"
            } else {
                let delta = frameTimestamps[i] - frameTimestamps[i-1]
                csvContent += "\(i+1),\(frameTimestamps[i]),\(delta)\n"
            }
        }
        
        // 結果をディスクに保存
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = desktopURL.appendingPathComponent("FrameRateTest_\(selectedTestFrameRate)fps_\(timestamp).csv")
        
        do {
            try csvContent.write(to: fileURL, atomically: true, encoding: .utf8)
            testResultMessage = "CSVファイルが保存されました: \(fileURL.lastPathComponent)"
            testResultSuccess = true
            
            // Finderで表示
            NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: "")
        } catch {
            testResultMessage = "保存エラー: \(error.localizedDescription)"
            testResultSuccess = false
        }
    }
    
    // テスト結果をクリップボードにコピー
    func copyTestResultsToClipboard() {
        guard hasTestResults else { return }
        
        var summaryText = """
        === フレームレートテスト結果 ===
        目標FPS: \(selectedTestFrameRate)
        測定FPS: \(String(format: "%.2f", measuredFPS))
        精度: \(String(format: "%.1f%%", fpsAccuracy * 100))
        テスト時間: \(String(format: "%.1f秒", testElapsedTime))
        フレーム数: \(frameTimestamps.count)
        
        """
        
        if hasAudioData {
            summaryText += """
            オーディオ情報:
            サンプルレート: \(Int(audioSampleRate))Hz
            チャンネル数: \(audioChannelCount)
            処理バッファ数: \(audioBuffersProcessed)
            
            """
        }
        
        summaryText += """
        フレーム間隔統計:
        """
        
        if let minDelta = frameDeltas.min(), let maxDelta = frameDeltas.max() {
            let avgDelta = frameDeltas.reduce(0, +) / Double(frameDeltas.count)
            summaryText += """
            
            平均: \(String(format: "%.4f秒", avgDelta)) (目標: \(String(format: "%.4f秒", 1.0/selectedTestFrameRate)))
            最小: \(String(format: "%.4f秒", minDelta))
            最大: \(String(format: "%.4f秒", maxDelta))
            """
        }
        
        // 追加情報の附加
        if hasAudioData && audioLatencyStats.count > 0 {
            let avgLatency = audioLatencyStats.reduce(0, +) / Double(audioLatencyStats.count)
            let minLatency = audioLatencyStats.min() ?? 0
            let maxLatency = audioLatencyStats.max() ?? 0
            
            summaryText += """
            
            音声処理レイテンシ:
            平均: \(String(format: "%.2f ms", avgLatency))
            最小: \(String(format: "%.2f ms", minLatency))
            最大: \(String(format: "%.2f ms", maxLatency))
            """
        }
        
        // メッセージの追加
        if let message = testResultMessage, !message.isEmpty {
            summaryText += """
            
            診断:
            \(message)
            """
        }
        
        // コピー
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summaryText, forType: .string)
        
        testResultMessage = "テスト結果がクリップボードにコピーされました"
        testResultSuccess = true
    }
    
    // フレームレート精度テスト実行
    func runFrameRateTest() async {
        // リセット
        isTestRunning = true
        isPerformanceTesting = true
        frameTimestamps = []
        frameDeltas = []
        testResultMessage = nil
        testElapsedTime = 0
        audioBuffersProcessed = 0
        audioLatencyStats = []
        hasAudioData = false
        
        do {
            // 利用可能なターゲット取得
            let targets = try await MediaCapture.availableCaptureTargets(ofType: .all)
            guard let target = targets.first else {
                testResultMessage = "エラー: キャプチャターゲットがありません"
                testResultSuccess = false
                isTestRunning = false
                isPerformanceTesting = false
                return
            }
            
            // テスト開始時間
            let startTime = Date().timeIntervalSince1970
            
            // テスト実行中のタイマー
            let timerTask = Task { @MainActor in
                while isTestRunning {
                    self.testElapsedTime = Date().timeIntervalSince1970 - startTime
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            
            // キャプチャ開始
            _ = try await mediaCapture.startCapture(
                target: target,
                mediaHandler: { [weak self] media in
                    guard let self = self else { return }
                    
                    let now = Date().timeIntervalSince1970
                    
                    // 音声バッファの処理（フレームレートに関係なく常に処理）
                    if let audioBuffer = media.audioBuffer, let audioInfo = media.metadata.audioInfo {
                        Task { @MainActor in
                            self.audioBuffersProcessed += 1
                            self.hasAudioData = true
                            
                            // 音声レイテンシの計算（ミリ秒）
                            let latency = (now - media.metadata.timestamp) * 1000
                            self.audioLatencyStats.append(latency)
                            
                            // 音声フォーマット情報の更新
                            if let captureVM = self.captureViewModel {
                                captureVM.audioSampleRate = audioInfo.sampleRate
                                captureVM.audioChannelCount = audioInfo.channelCount
                            }
                        }
                    }
                    
                    // ビデオフレームのみタイムスタンプを記録（フレームレートテスト用）
                    if let _ = media.videoBuffer {
                        let relativeTime = now - startTime
                        
                        // タイムスタンプを記録（UIスレッドで更新）
                        Task { @MainActor in
                            self.frameTimestamps.append(relativeTime)
                            
                            // フレーム間隔を計算（2フレーム目以降）
                            if self.frameTimestamps.count > 1 {
                                let delta = relativeTime - self.frameTimestamps[self.frameTimestamps.count - 2]
                                self.frameDeltas.append(delta)
                            }
                            
                            // 測定FPSと精度を計算
                            if self.frameTimestamps.count >= 2 {
                                let duration = self.frameTimestamps.last! - self.frameTimestamps.first!
                                if duration > 0 {
                                    self.measuredFPS = Double(self.frameTimestamps.count - 1) / duration
                                    self.fpsAccuracy = self.measuredFPS / self.selectedTestFrameRate
                                }
                            }
                        }
                    }
                },
                framesPerSecond: selectedTestFrameRate,
                quality: .high
            )
            
            // 指定時間だけ待機
            try await Task.sleep(for: .seconds(testDuration))
            
            // キャプチャ停止
            await mediaCapture.stopCapture()
            timerTask.cancel()
            
        } catch {
            testResultMessage = "エラー: \(error.localizedDescription)"
            testResultSuccess = false
        }
        
        isTestRunning = false
        isPerformanceTesting = false
    }
}