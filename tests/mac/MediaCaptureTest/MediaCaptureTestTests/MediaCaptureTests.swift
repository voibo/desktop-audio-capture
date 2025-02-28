import XCTest
import AVFoundation
import ScreenCaptureKit
@testable import MediaCaptureTest

/// MediaCaptureテスト - テストプランで環境変数を設定
final class MediaCaptureTests: XCTestCase {
    
    var mediaCapture: MediaCapture!
    
    /// 環境変数に基づいて適切なMediaCaptureインスタンスを作成
    override func setUpWithError() throws {
        try super.setUpWithError()
        // 環境変数USE_MOCK_CAPTUREが設定されている場合はモックを使用
        // XCTestPlanでこの環境変数を設定することで、テスト環境を切り替え可能
        if ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] == "1" {
            mediaCapture = MockMediaCapture()
            print("モックモードでMediaCaptureをテストします")
        } else {
            mediaCapture = MediaCapture()
            print("実環境でMediaCaptureをテストします")
        }
    }
    
    override func tearDownWithError() throws {
        if mediaCapture.isCapturing() {
            mediaCapture.stopCaptureSync()
        }
        mediaCapture = nil
        try super.tearDownWithError()
    }
    
    // MARK: - 基本機能テスト
    
    func testAvailableTargets() async throws {
        // 利用可能なウィンドウとディスプレイの取得
        let targets = try await MediaCapture.availableWindows()
        
        // 最低1つのターゲットは存在するはず
        XCTAssertFalse(targets.isEmpty, "利用可能なキャプチャターゲットがありません")
        
        // ターゲット情報の検証
        for target in targets {
            if target.isDisplay {
                XCTAssertGreaterThan(target.displayID, 0, "ディスプレイIDが無効です")
                XCTAssertFalse(target.frame.isEmpty, "ディスプレイのフレームが無効です")
            } else if target.isWindow {
                XCTAssertGreaterThan(target.windowID, 0, "ウィンドウIDが無効です")
                XCTAssertNotNil(target.title, "ウィンドウタイトルがnilです")
            }
        }
    }
    
    func testStartAndStopCapture() async throws {
        // 利用可能なターゲットを取得
        let targets = try await MediaCapture.availableWindows()
        guard !targets.isEmpty else {
            XCTFail("テスト用のキャプチャターゲットがありません")
            return
        }
        
        // 最初のターゲットを使用
        let target = targets[0]
        
        // キャプチャデータの受信を期待
        let expectation = expectation(description: "メディアデータを受信")
        var receivedData = false
        
        // キャプチャ開始
        let success = try await mediaCapture.startCapture(
            target: target,
            mediaHandler: { media in
                if !receivedData {
                    receivedData = true
                    expectation.fulfill()
                }
            }
        )
        
        // キャプチャ開始のチェック
        XCTAssertTrue(success, "キャプチャが正常に開始されるべき")
        XCTAssertTrue(mediaCapture.isCapturing(), "isCapturingがtrueを返すべき")
        
        // データ受信を待つ
        await fulfillment(of: [expectation], timeout: 5.0)
        XCTAssertTrue(receivedData, "メディアデータを受信したはず")
        
        // キャプチャ停止
        await mediaCapture.stopCapture()
        XCTAssertFalse(mediaCapture.isCapturing(), "isCapturingがfalseを返すべき")
    }
    
    func testSyncStopCapture() async throws {
        // 利用可能なターゲットを取得
        let targets = try await MediaCapture.availableWindows()
        guard !targets.isEmpty else {
            XCTFail("テスト用のキャプチャターゲットがありません")
            return
        }
        
        let target = targets[0]
        
        // キャプチャ開始
        _ = try await mediaCapture.startCapture(
            target: target,
            mediaHandler: { _ in }
        )
        
        XCTAssertTrue(mediaCapture.isCapturing(), "キャプチャが開始されるべき")
        
        // 同期的に停止
        mediaCapture.stopCaptureSync()
        XCTAssertFalse(mediaCapture.isCapturing(), "同期停止後はisCapturingがfalseを返すべき")
    }
    
    // MARK: - メディアデータ検証テスト
    
    func testMediaDataFormat() async throws {
        // 利用可能なターゲットを取得
        let targets = try await MediaCapture.availableWindows()
        guard !targets.isEmpty else {
            XCTFail("テスト用のキャプチャターゲットがありません")
            return
        }
        
        let target = targets[0]
        
        // メディアデータの期待
        let expectation = expectation(description: "有効なメディアデータを受信")
        
        // キャプチャ開始
        _ = try await mediaCapture.startCapture(
            target: target,
            mediaHandler: { media in
                // メタデータのチェック
                XCTAssertGreaterThan(media.metadata.timestamp, 0, "タイムスタンプは正の値であるべき")
                
                if let videoBuffer = media.videoBuffer, let videoInfo = media.metadata.videoInfo {
                    XCTAssertGreaterThan(videoInfo.width, 0, "幅は正の値であるべき")
                    XCTAssertGreaterThan(videoInfo.height, 0, "高さは正の値であるべき")
                    XCTAssertGreaterThan(videoInfo.bytesPerRow, 0, "バイト/行は正の値であるべき")
                    XCTAssertGreaterThan(videoBuffer.count, 0, "ビデオバッファは空でないべき")
                }
                
                if let audioBuffer = media.audioBuffer, let audioInfo = media.metadata.audioInfo {
                    XCTAssertGreaterThan(audioInfo.sampleRate, 0, "サンプルレートは正の値であるべき")
                    XCTAssertGreaterThanOrEqual(audioInfo.channelCount, 1, "チャンネル数は少なくとも1であるべき")
                    XCTAssertGreaterThan(audioBuffer.count, 0, "オーディオバッファは空でないべき")
                }
                
                expectation.fulfill()
            }
        )
        
        // データ受信を待つ
        await fulfillment(of: [expectation], timeout: 5.0)
        
        // キャプチャ停止
        await mediaCapture.stopCapture()
    }
    
    // MARK: - エラー処理テスト
    
    func testErrorHandling() async throws {
        // 無効なウィンドウIDでキャプチャを試みる
        let invalidTarget = MediaCaptureTarget(windowID: 99999, title: "存在しないウィンドウ")
        
        // エラー発生を期待
        let expectation = expectation(description: "エラーが発生する")
        var expectationFulfilled = false
        
        do {
            _ = try await mediaCapture.startCapture(
                target: invalidTarget,
                mediaHandler: { _ in },
                errorHandler: { _ in
                    // モックモードでは、エラーハンドラが呼ばれる
                    if ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] == "1" && !expectationFulfilled {
                        expectationFulfilled = true
                        expectation.fulfill()
                    }
                }
            )
            // モックモードではエラーをスローするが、実環境では無効なIDでも失敗しない場合がある
            if ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] == "1" {
                XCTFail("モックモードではエラーがスローされるべき")
            }
        } catch {
            // エラーが発生した場合は成功（期待値がまだ満たされていない場合のみ）
            if !expectationFulfilled {
                expectationFulfilled = true
                expectation.fulfill()
            }
        }
        
        // エラー処理を待つ（タイムアウト設定）
        await fulfillment(of: [expectation], timeout: 3.0)
        
        // キャプチャが開始されていないことを確認
        XCTAssertFalse(mediaCapture.isCapturing(), "エラー後はキャプチャが開始されていないはず")
    }
    
    // MARK: - 設定テスト
    
    func testDifferentQualitySettings() async throws {
        // 異なる品質設定でキャプチャできることを確認
        let qualities: [MediaCapture.CaptureQuality] = [.high, .medium, .low]
        let targets = try await MediaCapture.availableWindows()
        guard !targets.isEmpty else {
            XCTFail("テスト用のキャプチャターゲットがありません")
            return
        }
        
        let target = targets[0]
        
        for quality in qualities {
            // キャプチャ開始
            let expectation = expectation(description: "\(quality)品質でキャプチャ")
            
            _ = try await mediaCapture.startCapture(
                target: target,
                mediaHandler: { _ in
                    expectation.fulfill()
                },
                quality: quality
            )
            
            // データ受信を待つ
            await fulfillment(of: [expectation], timeout: 3.0)
            
            // キャプチャ停止
            await mediaCapture.stopCapture()
            
            // 次のテストのために少し待つ
            try await Task.sleep(for: .milliseconds(500))
        }
    }
    
    // MARK: - フレームレートテスト

    func testDifferentFrameRates() async throws {
        // 異なるフレームレートでキャプチャできることを確認
        let frameRates: [Double] = [30.0, 15.0, 5.0]
        let targets = try await MediaCapture.availableWindows()
        guard !targets.isEmpty else {
            XCTFail("テスト用のキャプチャターゲットがありません")
            return
        }
        
        let target = targets[0]
        
        for fps in frameRates {
            // キャプチャ開始
            let expectation = expectation(description: "\(fps)fpsでキャプチャ")
            
            _ = try await mediaCapture.startCapture(
                target: target,
                mediaHandler: { _ in
                    expectation.fulfill()
                },
                framesPerSecond: fps
            )
            
            // データ受信を待つ
            await fulfillment(of: [expectation], timeout: 3.0)
            
            // キャプチャ停止
            await mediaCapture.stopCapture()
            
            // 次のテストのために少し待つ
            try await Task.sleep(for: .milliseconds(500))
        }
    }
    
    // MARK: - メディアタイプテスト

    func testAudioOnlyCapture() async throws {
        // フレームレート0でオーディオのみのキャプチャをテスト
        let targets = try await MediaCapture.availableWindows()
        guard !targets.isEmpty else {
            XCTFail("テスト用のキャプチャターゲットがありません")
            return
        }
        
        let target = targets[0]
        let expectation = expectation(description: "オーディオデータを受信")
        var receivedAudioData = false
        var receivedVideoData = false
        
        _ = try await mediaCapture.startCapture(
            target: target,
            mediaHandler: { media in
                if media.audioBuffer != nil {
                    receivedAudioData = true
                }
                if media.videoBuffer != nil {
                    receivedVideoData = true
                }
                
                // オーディオデータを受信したら成功
                if receivedAudioData {
                    expectation.fulfill()
                }
            },
            framesPerSecond: 0.0 // フレームレート0はオーディオのみモードを意味する
        )
        
        // データ受信を待つ
        await fulfillment(of: [expectation], timeout: 5.0)
        
        // キャプチャ停止
        await mediaCapture.stopCapture()
        
        // オーディオはあるが、ビデオはないはず（モックモードでは両方とも来る可能性がある）
        XCTAssertTrue(receivedAudioData, "オーディオデータを受信するべき")
        if ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] != "1" {
            // 実環境でのみ検証（モックでは両方来る可能性あり）
            XCTAssertFalse(receivedVideoData, "ビデオデータを受信すべきでない")
        }
    }
    
    // MARK: - ターゲット情報テスト

    func testTargetProperties() async throws {
        // ターゲット情報の詳細検証
        let targets = try await MediaCapture.availableWindows()
        guard !targets.isEmpty else {
            XCTFail("利用可能なキャプチャターゲットがありません")
            return
        }
        
        // ウィンドウとディスプレイを検証
        let windows = targets.filter { $0.isWindow }
        let displays = targets.filter { $0.isDisplay }
        
        // ウィンドウ情報の検証
        for window in windows {
            XCTAssertTrue(window.isWindow, "isWindowはtrueを返すべき")
            XCTAssertFalse(window.isDisplay, "isDisplayはfalseを返すべき")
            XCTAssertGreaterThan(window.windowID, 0, "有効なウィンドウID")
            
            // ウィンドウにはタイトルか関連情報があるはず
            if let title = window.title {
                XCTAssertFalse(title.isEmpty, "ウィンドウタイトルは空でないべき")
            }
            
            // フレームがゼロでないことを確認
            XCTAssertFalse(window.frame.isEmpty, "ウィンドウフレームは空でないべき")
        }
        
        // ディスプレイ情報の検証
        for display in displays {
            XCTAssertTrue(display.isDisplay, "isDisplayはtrueを返すべき")
            XCTAssertFalse(display.isWindow, "isWindowはfalseを返すべき")
            XCTAssertGreaterThan(display.displayID, 0, "有効なディスプレイID")
            XCTAssertFalse(display.frame.isEmpty, "ディスプレイフレームは空でないべき")
        }
    }
    
    // MARK: - リソース管理テスト

    func testMultipleStartStopCycles() async throws {
        // 複数回のキャプチャ開始・停止で安定しているかテスト
        let targets = try await MediaCapture.availableWindows()
        guard !targets.isEmpty else {
            XCTFail("テスト用のキャプチャターゲットがありません")
            return
        }
        
        let target = targets[0]
        
        // 複数回キャプチャ開始・停止を繰り返す
        for i in 1...3 {
            print("キャプチャサイクル \(i)/3")
            
            let expectation = expectation(description: "キャプチャサイクル \(i)")
            
            // キャプチャ開始
            _ = try await mediaCapture.startCapture(
                target: target,
                mediaHandler: { _ in
                    expectation.fulfill()
                }
            )
            
            // データ受信を待つ
            await fulfillment(of: [expectation], timeout: 3.0)
            
            // キャプチャ停止
            await mediaCapture.stopCapture()
            
            // 次のサイクルのために少し待つ
            try await Task.sleep(for: .milliseconds(500))
        }
        
        // 全てのサイクルが完了した後、キャプチャ状態が正しく設定されているか確認
        XCTAssertFalse(mediaCapture.isCapturing(), "最終的にキャプチャは停止しているべき")
    }
}
