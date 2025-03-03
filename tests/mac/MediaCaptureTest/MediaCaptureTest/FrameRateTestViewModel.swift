import SwiftUI
import AVFoundation
import ScreenCaptureKit

class FrameRateTestViewModel: ObservableObject {
    @Published var mediaCapture: MediaCapture?
    @Published var isRunningTest: Bool = false
    @Published var currentTest: String = ""
    @Published var testResults: [String] = []
    // selectedTargetプロパティの代わりにインデックスベースの選択に変更
    @Published var selectedTargetIndex: Int = 0
    @Published var availableTargets: [MediaCaptureTarget] = []
    @Published var progressValue: Double = 0
    @Published var testStatus: String = ""
    @Published var enableLogging: Bool = true
    
    // selectedTargetをコンピューテッドプロパティとして定義
    var selectedTarget: MediaCaptureTarget? {
        guard !availableTargets.isEmpty, selectedTargetIndex < availableTargets.count else {
            return nil
        }
        return availableTargets[selectedTargetIndex]
    }
    
    // テスト設定パラメータ
    @Published var framesToCapture: Int = 5
    @Published var targetFrameRate: Double = 15.0
    @Published var allowedFrameRateError: Double = 0.3
    @Published var lowFrameRate: Double = 0.5
    @Published var testDuration: Double = 8.0
    
    // テスト中のデータ
    private var videoFrames: [(timestamp: Double, index: Int)] = []
    private var audioFrames: [(timestamp: Double, index: Int)] = []
    private var frameCount: Int = 0
    private var audioFrameCount: Int = 0
    
    init() {
        loadAvailableTargets()
    }
    
    func loadAvailableTargets() {
        Task { @MainActor in
            self.testStatus = "キャプチャターゲットを読み込み中..."
            do {
                self.availableTargets = try await MediaCapture.availableCaptureTargets(ofType: .all)
                // インデックスをリセット
                self.selectedTargetIndex = self.availableTargets.isEmpty ? 0 : 0
                self.testStatus = "ターゲット読み込み完了: \(self.availableTargets.count)個"
            } catch {
                self.logMessage("ターゲット読み込みエラー: \(error.localizedDescription)")
                self.testStatus = "ターゲット読み込み失敗"
            }
        }
    }
    
    func logMessage(_ message: String) {
        if enableLogging {
            testResults.append(message)
            print(message)
        }
    }
    
    func clearResults() {
        testResults.removeAll()
    }
    
    // テスト1: フレームレート精度と音声連続性テスト
    func runFrameRateAccuracyTest() async {
        guard let target = selectedTarget else {
            logMessage("エラー: テスト対象が選択されていません")
            return
        }
        
        await runTest(name: "フレームレート精度テスト") {
            self.logMessage("\n==== フレームレート精度テスト開始 ====")
            self.logMessage("テストフレームレート: \(self.targetFrameRate)fps")
            
            // テストデータをリセット
            self.videoFrames = []
            self.audioFrames = []
            self.frameCount = 0
            
            // メディアキャプチャ作成
            self.mediaCapture = MediaCapture(forceMockCapture: false) // 実機テスト
            
            // 期待値の設定
            let frameInterval = 1.0 / self.targetFrameRate
            
            // キャプチャ開始
            self.logMessage("キャプチャ開始...")
            let success = try await self.mediaCapture?.startCapture(
                target: target,
                mediaHandler: { media in
                    let currentTime = CACurrentMediaTime()
                    self.frameCount += 1
                    
                    // ビデオデータの確認
                    if media.videoBuffer != nil, self.videoFrames.count < self.framesToCapture {
                        self.videoFrames.append((timestamp: currentTime, index: self.frameCount))
                        let progress = Double(self.videoFrames.count) / Double(self.framesToCapture)
                        Task { @MainActor in
                            self.progressValue = progress
                            self.testStatus = "ビデオフレーム受信: \(self.videoFrames.count)/\(self.framesToCapture)"
                        }
                    }
                    
                    // オーディオデータの確認
                    if media.audioBuffer != nil, self.audioFrames.count < self.framesToCapture * 2 {
                        self.audioFrames.append((timestamp: currentTime, index: self.frameCount))
                    }
                },
                framesPerSecond: self.targetFrameRate,
                quality: .high
            ) ?? false
            
            self.logMessage("キャプチャ開始結果: \(success ? "成功" : "失敗")")
            
            // 必要なビデオフレーム数を待つためのセマフォ
            let semaphore = DispatchSemaphore(value: 0)
            
            // タイムアウトを設定
            let timeoutTask = Task {
                try await Task.sleep(for: .seconds(15))
                semaphore.signal() // タイムアウト
            }
            
            // フレーム監視タスク
            Task {
                while self.videoFrames.count < self.framesToCapture && !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(100))
                    if self.videoFrames.count >= self.framesToCapture {
                        timeoutTask.cancel()
                        semaphore.signal()
                    }
                }
            }
            
            // フレームが集まるまで待機
            semaphore.wait()
            
            // キャプチャを停止
            await self.mediaCapture?.stopCapture()
            
            // 結果分析
            await self.analyzeFrameRateResults(frameInterval: frameInterval)
        }
    }
    
    @MainActor
    private func analyzeFrameRateResults(frameInterval: Double) {
        // 結果の検証
        if videoFrames.count < framesToCapture {
            logMessage("⚠️ 警告: 期待した数のビデオフレームを受信していません (\(videoFrames.count)/\(framesToCapture))")
        } else {
            logMessage("✅ ビデオフレーム数: \(videoFrames.count)/\(framesToCapture)")
        }
        
        if audioFrames.count < framesToCapture {
            logMessage("⚠️ 警告: 音声フレーム数が不足しています (\(audioFrames.count))")
        } else {
            logMessage("✅ 音声フレーム数: \(audioFrames.count)")
        }
        
        // ビデオフレーム間隔の精度を検証
        if videoFrames.count > 1 {
            var totalFrameIntervalError: Double = 0.0
            for i in 1..<videoFrames.count {
                let actualInterval = videoFrames[i].timestamp - videoFrames[i-1].timestamp
                let intervalError = abs(actualInterval - frameInterval) / frameInterval
                
                logMessage("フレーム間隔 \(i): 期待値 \(String(format: "%.4f", frameInterval))秒, 実際 \(String(format: "%.4f", actualInterval))秒, 誤差 \(String(format: "%.1f", intervalError * 100))%")
                
                totalFrameIntervalError += intervalError
            }
            
            // 平均誤差を計算
            let averageFrameIntervalError = totalFrameIntervalError / Double(videoFrames.count - 1)
            logMessage("フレームレート誤差の平均: \(String(format: "%.1f", averageFrameIntervalError * 100))%")
            
            // フレームレートの精度を検証
            if averageFrameIntervalError < allowedFrameRateError {
                logMessage("✅ フレームレート精度は許容範囲内です")
            } else {
                logMessage("❌ フレームレートの誤差が許容範囲を超えています: \(String(format: "%.1f", averageFrameIntervalError * 100))%")
            }
        }
        
        // 音声データの連続性を検証
        if videoFrames.count > 0 && audioFrames.count > 0 {
            let audioFrameRatio = Double(audioFrames.count) / Double(videoFrames.count)
            logMessage("オーディオ/ビデオフレーム比率: \(String(format: "%.2f", audioFrameRatio))")
            
            if audioFrameRatio >= 1.0 {
                logMessage("✅ 音声データは十分な頻度で受信されています")
            } else {
                logMessage("❌ 音声データが十分な頻度で受信されていません")
            }
            
            // 音声フレームの間に大きな間隙がないかを確認
            if audioFrames.count > 1 {
                var maxAudioInterval: Double = 0.0
                for i in 1..<audioFrames.count {
                    let interval = audioFrames[i].timestamp - audioFrames[i-1].timestamp
                    maxAudioInterval = max(maxAudioInterval, interval)
                }
                
                logMessage("最大音声フレーム間隔: \(String(format: "%.4f", maxAudioInterval))秒")
                
                // 音声の最大間隔はフレーム間隔の3倍以内であるべき
                if maxAudioInterval < frameInterval * 3 {
                    logMessage("✅ 音声データは連続的に受信されています")
                } else {
                    logMessage("❌ 音声データの連続性に問題があります")
                }
            }
        }
    }
    
    // テスト2: 低フレームレート動作テスト
    func runLowFrameRateTest() async {
        // 同様に実装
        // 省略
    }
    
    // テスト3: オーディオのみのモードテスト
    func runAudioOnlyModeTest() async {
        // 同様に実装
        // 省略
    }
    
    // テスト4: 異なるフレームレートテスト
    func runDifferentFrameRatesTest() async {
        guard let target = selectedTarget else {
            logMessage("エラー: テスト対象が選択されていません")
            return
        }
        
        await runTest(name: "異なるフレームレートテスト") {
            self.logMessage("\n==== 異なるフレームレートテスト開始 ====")
            
            // テストするフレームレート配列
            let frameRates: [Double] = [30.0, 15.0, 5.0]
            var testResults: [(fps: Double, frameCount: Int, duration: Double)] = []
            
            // メディアキャプチャ作成
            self.mediaCapture = MediaCapture(forceMockCapture: false) // 実機テスト
            
            for (index, fps) in frameRates.enumerated() {
                let progress = Double(index) / Double(frameRates.count)
                
                await MainActor.run {
                    self.progressValue = progress
                    self.testStatus = "\(fps) fps のテスト実行中..."
                }
                
                self.logMessage("\n-- フレームレート \(fps)fps のテスト --")
                
                // テストデータをリセット
                var frameCount = 0
                var firstFrameTime: Double = 0
                var lastFrameTime: Double = 0
                let framesNeeded = 3  // 各フレームレートで3フレームを取得
                
                // セマフォと同期オブジェクト
                let semaphore = DispatchSemaphore(value: 0)
                let lock = NSLock()
                
                // キャプチャ開始
                let success = try await self.mediaCapture?.startCapture(
                    target: target,
                    mediaHandler: { media in
                        if media.videoBuffer != nil {
                            let currentTime = CACurrentMediaTime()
                            
                            lock.lock()
                            if frameCount == 0 {
                                firstFrameTime = currentTime
                            }
                            frameCount += 1
                            lastFrameTime = currentTime
                            
                            // 必要なフレーム数に達したらセマフォを解放
                            if frameCount >= framesNeeded {
                                semaphore.signal()
                            }
                            lock.unlock()
                            
                            Task { @MainActor in
                                self.testStatus = "\(fps) fps: \(frameCount)/\(framesNeeded)フレーム"
                            }
                        }
                    },
                    framesPerSecond: fps
                ) ?? false
                
                self.logMessage("キャプチャ開始結果: \(success ? "成功" : "失敗")")
                
                // タイムアウトタスク
                let timeoutTask = Task {
                    // フレームレートに応じたタイムアウト設定（低フレームレートほど長く）
                    let timeout = max(10.0, Double(framesNeeded) * 1.5 / fps)
                    try await Task.sleep(for: .seconds(timeout))
                    semaphore.signal()
                }
                
                // フレームが集まるまで待機
                semaphore.wait()
                timeoutTask.cancel()
                
                // キャプチャを停止
                await self.mediaCapture?.stopCapture()
                
                // 結果の分析
                if frameCount >= framesNeeded && lastFrameTime > firstFrameTime {
                    let duration = lastFrameTime - firstFrameTime
                    let actualFps = Double(frameCount - 1) / duration
                    let fpsError = abs(actualFps - fps) / fps
                    
                    testResults.append((fps: fps, frameCount: frameCount, duration: duration))
                    
                    self.logMessage("フレームレート\(fps)fps結果:")
                    self.logMessage("  フレーム数: \(frameCount)")
                    self.logMessage("  経過時間: \(String(format: "%.2f", duration))秒")
                    self.logMessage("  実測FPS: \(String(format: "%.1f", actualFps))")
                    self.logMessage("  誤差率: \(String(format: "%.1f", fpsError * 100))%")
                    
                    if fpsError <= 0.3 {  // 30%誤差まで許容
                        self.logMessage("  ✅ 許容誤差内")
                    } else {
                        self.logMessage("  ❌ 許容誤差を超過")
                    }
                } else {
                    self.logMessage("❌ \(fps)fps: 十分なフレームが取得できませんでした")
                }
                
                // 次のフレームレート検証前に少し待機
                try await Task.sleep(for: .milliseconds(500))
            }
            
            // 総評
            self.logMessage("\n異なるフレームレートテスト結果概要:")
            for result in testResults {
                self.logMessage("• \(String(format: "%.0f", result.fps))fps: \(result.frameCount)フレーム / \(String(format: "%.2f", result.duration))秒")
            }
        }
    }
    
    // テスト5: 極端なフレームレートテスト
    func runExtremeFrameRatesTest() async {
        guard let target = selectedTarget else {
            logMessage("エラー: テスト対象が選択されていません")
            return
        }
        
        await runTest(name: "極端なフレームレートテスト") {
            self.logMessage("\n==== 極端なフレームレートテスト開始 ====")
            
            // 極端なフレームレート
            let frameRates: [Double] = [0.5, 60.0, 120.0]  // 0.5fps (2秒に1フレーム), 60fps, 120fps
            var testResults: [(fps: Double, success: Bool, frameCount: Int)] = []
            
            // メディアキャプチャ作成
            self.mediaCapture = MediaCapture(forceMockCapture: false) // 実機テスト
            
            for (index, fps) in frameRates.enumerated() {
                let progress = Double(index) / Double(frameRates.count)
                
                await MainActor.run {
                    self.progressValue = progress
                    self.testStatus = "フレームレート \(fps)fps をテスト中..."
                }
                
                self.logMessage("\n-- 極端なフレームレート \(fps)fps のテスト --")
                
                // 各フレームレートでのテスト要件
                let framesNeeded = fps < 1.0 ? 2 : 10  // 低フレームレートでは少なめのフレーム
                let timeout = fps < 1.0 ? 10.0 : 5.0   // 低フレームレートでは長めのタイムアウト
                
                // テストデータ
                var frameCount = 0
                var startTime: Double = 0
                
                // セマフォ
                let semaphore = DispatchSemaphore(value: 0)
                
                // キャプチャ開始
                let success = try await self.mediaCapture?.startCapture(
                    target: target,
                    mediaHandler: { media in
                        if media.videoBuffer != nil {
                            if frameCount == 0 {
                                startTime = CACurrentMediaTime()
                            }
                            frameCount += 1
                            
                            Task { @MainActor in
                                self.testStatus = "\(fps) fps: \(frameCount)/\(framesNeeded)フレーム"
                                if frameCount >= framesNeeded {
                                    semaphore.signal()
                                }
                            }
                        }
                    },
                    framesPerSecond: fps
                ) ?? false
                
                // キャプチャ開始結果
                self.logMessage("キャプチャ開始: \(success ? "成功" : "失敗")")
                
                if success {
                    // タイムアウトタスク
                    let timeoutTask = Task {
                        try await Task.sleep(for: .seconds(timeout))
                        semaphore.signal()
                    }
                    
                    // フレームを待機
                    semaphore.wait()
                    timeoutTask.cancel()
                    
                    // キャプチャ停止
                    await self.mediaCapture?.stopCapture()
                    
                    // 結果記録
                    let endTime = CACurrentMediaTime()
                    let duration = endTime - startTime
                    let achievedFrames = frameCount >= framesNeeded
                    
                    testResults.append((fps: fps, success: achievedFrames, frameCount: frameCount))
                    
                    if frameCount > 0 {
                        let actualFps = Double(frameCount) / duration
                        self.logMessage("結果:")
                        self.logMessage("  キャプチャ時間: \(String(format: "%.2f", duration))秒")
                        self.logMessage("  取得フレーム数: \(frameCount)")
                        self.logMessage("  実測FPS: \(String(format: "%.2f", actualFps))")
                        
                        if achievedFrames {
                            self.logMessage("  ✅ 必要なフレーム数を取得できました")
                        } else {
                            self.logMessage("  ❌ 必要なフレーム数を取得できませんでした")
                        }
                    } else {
                        self.logMessage("❌ フレームが1つも取得できませんでした")
                    }
                } else {
                    testResults.append((fps: fps, success: false, frameCount: 0))
                    self.logMessage("❌ キャプチャの開始に失敗しました")
                }
                
                // 次のテスト前に少し待機
                try await Task.sleep(for: .milliseconds(800))
            }
            
            // 総評
            self.logMessage("\n極端なフレームレートテスト結果概要:")
            for result in testResults {
                let status = result.success ? "✅ 成功" : "❌ 失敗"
                self.logMessage("• \(String(format: "%.1f", result.fps))fps: \(status) (\(result.frameCount)フレーム)")
            }
        }
    }
    
    // テスト6: 長時間キャプチャテスト
    func runExtendedCaptureTest() async {
        guard let target = selectedTarget else {
            logMessage("エラー: テスト対象が選択されていません")
            return
        }
        
        await runTest(name: "長時間キャプチャテスト") {
            self.logMessage("\n==== 長時間キャプチャテスト開始 ====")
            
            // テストパラメータ
            let fps = 15.0
            let captureDuration = self.testDuration  // UIから設定された時間
            
            self.logMessage("テスト設定:")
            self.logMessage("  フレームレート: \(fps)fps")
            self.logMessage("  キャプチャ時間: \(String(format: "%.1f", captureDuration))秒")
            
            // メディアキャプチャ作成
            self.mediaCapture = MediaCapture(forceMockCapture: false) // 実機テスト
            
            // テストデータ
            var frameCount = 0
            var audioCount = 0
            var firstFrameTime: Double = 0
            var lastFrameTime: Double = 0
            var maxInterval: Double = 0
            var framesWithLongInterval = 0
            let expectedInterval = 1.0 / fps
            
            // キャプチャ開始
            self.logMessage("キャプチャ開始...")
            let success = try await self.mediaCapture?.startCapture(
                target: target,
                mediaHandler: { media in
                    let currentTime = CACurrentMediaTime()
                    
                    if media.videoBuffer != nil {
                        if frameCount == 0 {
                            firstFrameTime = currentTime
                        } else {
                            // フレーム間隔を計算
                            let interval = currentTime - lastFrameTime
                            maxInterval = max(maxInterval, interval)
                            
                            // 期待間隔よりも50%以上長い場合はカウント
                            if interval > expectedInterval * 1.5 {
                                framesWithLongInterval += 1
                            }
                        }
                        
                        frameCount += 1
                        lastFrameTime = currentTime
                        
                        // 進捗表示の更新
                        let elapsedTime = currentTime - firstFrameTime
                        let progress = min(1.0, elapsedTime / captureDuration)
                        
                        Task { @MainActor in
                            self.progressValue = progress
                            self.testStatus = "キャプチャ中: \(frameCount)フレーム / \(String(format: "%.1f", elapsedTime))秒"
                        }
                    }
                    
                    if media.audioBuffer != nil {
                        audioCount += 1
                    }
                },
                framesPerSecond: fps
            ) ?? false
            
            if !success {
                self.logMessage("❌ キャプチャの開始に失敗しました")
                return
            }
            
            // 指定時間キャプチャを継続
            do {
                // 経過表示タスク
                let progressTask = Task {
                    let start = CACurrentMediaTime()
                    while !Task.isCancelled {
                        let elapsed = CACurrentMediaTime() - start
                        let progress = min(1.0, elapsed / captureDuration)
                        await MainActor.run {
                            self.progressValue = progress
                        }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
                
                // 指定時間待機
                try await Task.sleep(for: .seconds(captureDuration))
                progressTask.cancel()
                
                // キャプチャ停止
                await self.mediaCapture?.stopCapture()
                
                // 結果分析
                let totalDuration = lastFrameTime - firstFrameTime
                let averageFps = frameCount > 1 ? Double(frameCount - 1) / totalDuration : 0
                let audioPerSecond = Double(audioCount) / max(1, totalDuration)
                
                self.logMessage("\n長時間キャプチャ結果:")
                self.logMessage("  総キャプチャ時間: \(String(format: "%.1f", totalDuration))秒")
                self.logMessage("  取得ビデオフレーム数: \(frameCount)")
                self.logMessage("  平均FPS: \(String(format: "%.2f", averageFps))")
                self.logMessage("  音声サンプル数: \(audioCount) (\(String(format: "%.1f", audioPerSecond))/秒)")
                self.logMessage("  最大フレーム間隔: \(String(format: "%.3f", maxInterval))秒")
                self.logMessage("  長い間隔のフレーム: \(framesWithLongInterval)個")
                
                // 基本的な検証
                if frameCount > 0 {
                    self.logMessage("✅ フレームを取得できました")
                } else {
                    self.logMessage("❌ フレームを1つも取得できませんでした")
                }
                
                if averageFps >= fps * 0.7 {
                    self.logMessage("✅ 平均FPSは目標の70%以上です")
                } else {
                    self.logMessage("❌ 平均FPSが目標の70%未満です")
                }
                
                if Double(framesWithLongInterval) <= Double(frameCount) * 0.1 {
                    self.logMessage("✅ 長い間隔のフレーム数は許容範囲内です")
                } else {
                    self.logMessage("❌ 長い間隔のフレーム数が多すぎます")
                }
                
                if audioCount > frameCount * 2 {
                    self.logMessage("✅ 十分な音声サンプルが取得できました")
                } else {
                    self.logMessage("⚠️ 音声サンプルが少ない可能性があります")
                }
                
            } catch {
                self.logMessage("❌ テスト中にエラー発生: \(error.localizedDescription)")
                await self.mediaCapture?.stopCapture()
            }
        }
    }
    
    // 他のテストも同様に実装
    
    // テストヘルパーメソッド
    private func runTest(name: String, testBlock: @escaping () async throws -> Void) async {
        guard !isRunningTest else {
            logMessage("別のテストが実行中です")
            return
        }
        
        await MainActor.run {
            self.isRunningTest = true
            self.currentTest = name
            self.progressValue = 0
            self.testStatus = "\(name)を開始..."
        }
        
        do {
            try await testBlock()
            await MainActor.run {
                self.testStatus = "\(name)が完了しました"
            }
        } catch {
            await MainActor.run {
                self.logMessage("テストエラー: \(error.localizedDescription)")
                self.testStatus = "\(name)が失敗しました"
            }
        }
        
        await MainActor.run {
            self.isRunningTest = false
        }
    }
}
