import AVFoundation
import CaptureC
import Foundation
import ScreenCaptureKit

private struct MediaSendableContext<T>: @unchecked Sendable {
    let value: T
}

// MediaCapture専用のウィンドウフィルタリング関数 - Bridge.swiftと共有しない
fileprivate func filterMediaWindows(_ windows: [SCWindow]) -> [SCWindow] {
    windows
        // Sort the windows by app name.
        .sorted { $0.owningApplication?.applicationName ?? "" < $1.owningApplication?.applicationName ?? "" }
        // Remove windows that don't have an associated .app bundle.
        .filter { $0.owningApplication != nil && $0.owningApplication?.applicationName != "" }
        // Remove this app's window from the list.
        .filter { $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }
}

// MediaCapture専用のコンテンツフィルター関数
fileprivate func createMediaContentFilter(displayID: UInt32, windowID: UInt32, isAppExcluded: Bool) async throws -> SCContentFilter? {
    let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let availableDisplays = availableContent.displays
    let availableWindows = filterMediaWindows(availableContent.windows)
    let availableApps = availableContent.applications

    var filter: SCContentFilter
    if displayID > 0 {
        guard let display = findMediaDisplay(availableDisplays, displayID) else { return nil }
        var excludedApps = [SCRunningApplication]()
        if isAppExcluded {
            excludedApps = availableApps.filter { app in
                Bundle.main.bundleIdentifier == app.bundleIdentifier
            }
        }
        filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )
    } else if windowID > 0 {
        guard let window = findMediaWindow(availableWindows, windowID) else { return nil }
        filter = SCContentFilter(desktopIndependentWindow: window)
    } else {
        return nil
    }

    return filter
}

fileprivate func findMediaDisplay(_ displays: [SCDisplay], _ displayID: UInt32) -> SCDisplay? {
    for display in displays {
        if display.displayID == displayID {
            return display
        }
    }
    return nil
}

fileprivate func findMediaWindow(_ windows: [SCWindow], _ windowID: UInt32) -> SCWindow? {
    for window in windows {
        if window.windowID == windowID {
            return window
        }
    }
    return nil
}

// ------ MediaCapture専用のブリッジ関数 ------

@_cdecl("createMediaCapture")
public func createMediaCapture() -> UnsafeMutableRawPointer {
    let capture = MediaCapture()
    return Unmanaged.passRetained(capture).toOpaque()
}

@_cdecl("destroyMediaCapture")
public func destroyMediaCapture(_ p: UnsafeMutableRawPointer) {
    Unmanaged<MediaCapture>.fromOpaque(p).release()
}

public typealias EnumerateMediaCaptureTargetsCallback = @convention(c) (
    UnsafePointer<MediaCaptureTargetC>?, Int32, UnsafePointer<Int8>?, UnsafeRawPointer?
) -> Void

@_cdecl("enumerateMediaCaptureTargets") 
public func enumerateMediaCaptureTargets(_ type: Int32, _ callback: EnumerateMediaCaptureTargetsCallback, _ context: UnsafeRawPointer?) {
    fputs("DEBUG: enumerateMediaCaptureTargets called with type \(type)\n", stderr)
    
    // 非同期処理を同期的に行うための回避策
    let sendableCtx = MediaSendableContext(value: context)
    
    Task {
        do {
            let targetType: MediaCapture.CaptureTargetType
            switch type {
            case 0:
                targetType = .all
            case 1:
                targetType = .screen
            case 2:
                targetType = .window
            default:
                targetType = .all
            }
            
            fputs("DEBUG: Fetching available targets of type \(targetType)...\n", stderr)
            
            // 実際のターゲット一覧を取得
            let availableTargets = try await MediaCapture.availableCaptureTargets(ofType: targetType)
            fputs("DEBUG: Found \(availableTargets.count) available targets\n", stderr)
            
            // C構造体に変換
            var targets = [MediaCaptureTargetC]()
            
            for target in availableTargets {
                var cTarget = MediaCaptureTargetC()
                cTarget.isDisplay = target.isDisplay ? 1 : 0
                cTarget.isWindow = target.isWindow ? 1 : 0
                cTarget.displayID = target.displayID
                cTarget.windowID = target.windowID
                cTarget.width = Int32(target.frame.width)
                cTarget.height = Int32(target.frame.height)
                
                // 文字列をC形式に変換
                if let title = target.title {
                    cTarget.title = strdup(title)
                } else {
                    cTarget.title = nil
                }
                
                if let appName = target.applicationName {
                    cTarget.appName = strdup(appName)
                } else {
                    cTarget.appName = nil
                }
                
                targets.append(cTarget)
            }
            
            // メモリ解放用のdefer
            defer {
                for target in targets {
                    if let title = target.title {
                        free(title)
                    }
                    if let appName = target.appName {
                        free(appName)
                    }
                }
            }
            
            fputs("DEBUG: Calling C callback with \(targets.count) targets\n", stderr)
            
            // コールバックでデータを返す
            let context = sendableCtx.value
            targets.withUnsafeBufferPointer { ptr in
                callback(ptr.baseAddress, Int32(targets.count), nil, context)
            }
            
            fputs("DEBUG: Callback completed successfully\n", stderr)
        } catch {
            fputs("DEBUG: Error during target enumeration: \(error.localizedDescription)\n", stderr)
            let context = sendableCtx.value
            error.localizedDescription.withCString { ptr in
                callback(nil, 0, ptr, context)
            }
        }
    }
}

// MediaCapture用コールバック型定義
public typealias MediaCaptureDataCallback = @convention(c) (
    UnsafePointer<UInt8>?, Int32, Int32, Int32, Int32, UnsafeRawPointer?
) -> Void

public typealias MediaCaptureAudioDataCallback = @convention(c) (
    Int32, Int32, UnsafePointer<Float32>?, Int32, UnsafeRawPointer?
) -> Void

public typealias MediaCaptureExitCallback = @convention(c) (
    UnsafePointer<Int8>?, UnsafeRawPointer?
) -> Void

// MediaCapture用のStopCaptureCallback - AudioCaptureと共有しない
@_cdecl("startMediaCapture")
public func startMediaCapture(
    _ p: UnsafeMutableRawPointer,
    _ config: MediaCaptureConfigC,
    _ videoCallback: MediaCaptureDataCallback,
    _ audioCallback: MediaCaptureAudioDataCallback,
    _ exitCallback: MediaCaptureExitCallback,
    _ context: UnsafeMutableRawPointer?
) {
    fputs("DEBUG: startMediaCapture called\n", stderr)
    
    let capture = Unmanaged<MediaCapture>.fromOpaque(p).takeUnretainedValue()
    let sendableCtx = MediaSendableContext(value: context)
    
    Task {
        let context = sendableCtx.value
        
        do {
            // 設定の処理
            let quality: MediaCapture.CaptureQuality
            switch config.quality {
                case 0: quality = .high
                case 2: quality = .low
                default: quality = .medium
            }
            
            fputs("DEBUG: Configured quality: \(quality)\n", stderr)
            
            // ターゲット検証
            if config.displayID == 0 && config.windowID == 0 && config.bundleID == nil {
                fputs("DEBUG: No valid capture target specified\n", stderr)
                "No valid capture target specified".withCString { ptr in
                    exitCallback(ptr, context)
                }
                return
            }
            
            // 対象のディスプレイまたはウィンドウを見つける
            var target: MediaCaptureTarget?
            
            if config.displayID > 0 {
                fputs("DEBUG: Finding display with ID \(config.displayID)\n", stderr)
                let targets = try await MediaCapture.availableCaptureTargets(ofType: .screen)
                target = targets.first { $0.displayID == config.displayID }
                
                if target == nil {
                    fputs("DEBUG: Display with ID \(config.displayID) not found\n", stderr)
                }
            } else if config.windowID > 0 {
                fputs("DEBUG: Finding window with ID \(config.windowID)\n", stderr)
                let targets = try await MediaCapture.availableCaptureTargets(ofType: .window)
                target = targets.first { $0.windowID == config.windowID }
                
                if target == nil {
                    fputs("DEBUG: Window with ID \(config.windowID) not found\n", stderr)
                }
            } else if let bundleID = config.bundleID {
                fputs("DEBUG: Finding app with bundle ID \(String(cString: bundleID))\n", stderr)
                // アプリケーションバンドルIDでの検索を実装
                let targets = try await MediaCapture.availableCaptureTargets(ofType: .window)
                let bundleIDStr = String(cString: bundleID)
                // アプリ名での検索に変更（実際のAPIに合わせて調整）
                target = targets.first { 
                    // ターゲットに関連付けられたアプリ名があれば比較
                    if let appName = $0.applicationName {
                        // バンドルIDの代わりにアプリ名を部分一致検索
                        return appName.contains(bundleIDStr)
                    }
                    return false
                }
                
                if target == nil {
                    fputs("DEBUG: App with bundle ID \(String(cString: bundleID)) not found\n", stderr)
                }
            }
            
            guard let captureTarget = target else {
                fputs("DEBUG: No valid capture target found\n", stderr)
                "No valid capture target found".withCString { ptr in
                    exitCallback(ptr, context)
                }
                return
            }
            
            let targetDesc = captureTarget.isDisplay ? 
                "Display ID=\(captureTarget.displayID)" : 
                "Window ID=\(captureTarget.windowID)" + 
                (captureTarget.title != nil ? ", Title=\"\(captureTarget.title!)\"" : "") +
                (captureTarget.applicationName != nil ? ", App=\"\(captureTarget.applicationName!)\"" : "")
            fputs("DEBUG: Starting capture with target: \(targetDesc), Size=\(Int(captureTarget.frame.width))x\(Int(captureTarget.frame.height))\n", stderr)
            
            // キャプチャ開始
            let success = try await capture.startCapture(
                target: captureTarget,
                mediaHandler: { media in
                    // メディアデータのデバッグ情報
                    let hasVideo = media.videoBuffer != nil
                    let hasAudio = media.audioBuffer != nil
                    let videoInfoExists = media.metadata.videoInfo != nil
                    let audioInfoExists = media.metadata.audioInfo != nil
                    
                    fputs("DEBUG: Received media data - Video: \(hasVideo), Audio: \(hasAudio), VideoInfo: \(videoInfoExists), AudioInfo: \(audioInfoExists)\n", stderr)
                    
                    // ビデオデータの処理
                    if let videoBuffer = media.videoBuffer, 
                       let videoInfo = media.metadata.videoInfo {
                        
                        fputs("DEBUG: Processing video frame \(videoInfo.width)x\(videoInfo.height)\n", stderr)
                        
                        // 静的バッファ使用してメモリコピーを回避
                        videoBuffer.withUnsafeBytes { buffer in
                            guard let baseAddress = buffer.baseAddress else {
                                fputs("DEBUG: Failed to get video buffer base address\n", stderr)
                                return
                            }
                            
                            let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
                            let timestamp = Int32(media.metadata.timestamp * 1000) // ミリ秒単位
                            
                            fputs("DEBUG: Calling video callback with \(buffer.count) bytes\n", stderr)
                            videoCallback(
                                ptr,
                                Int32(videoInfo.width),
                                Int32(videoInfo.height),
                                Int32(videoInfo.bytesPerRow),
                                timestamp,
                                context
                            )
                        }
                    }
                    
                    // オーディオデータの処理
                    if let audioBuffer = media.audioBuffer,
                       let audioInfo = media.metadata.audioInfo {
                        
                        fputs("DEBUG: Processing audio data - \(audioInfo.channelCount) channels, \(audioInfo.frameCount) frames\n", stderr)
                        
                        audioBuffer.withUnsafeBytes { buffer in
                            guard let baseAddress = buffer.baseAddress else {
                                fputs("DEBUG: Failed to get audio buffer base address\n", stderr)
                                return
                            }
                            
                            let floatPtr = baseAddress.assumingMemoryBound(to: Float32.self)
                            
                            fputs("DEBUG: Calling audio callback with \(buffer.count / MemoryLayout<Float32>.stride) samples\n", stderr)
                            audioCallback(
                                Int32(audioInfo.channelCount),
                                Int32(audioInfo.sampleRate),
                                floatPtr,
                                Int32(audioInfo.frameCount),
                                context
                            )
                        }
                    }
                },
                errorHandler: { error in
                    fputs("DEBUG: Media capture error: \(error)\n", stderr)
                    error.withCString { ptr in
                        exitCallback(ptr, context)
                    }
                },
                framesPerSecond: Double(config.frameRate),
                quality: quality
            )
            
            if success {
                fputs("DEBUG: Media capture started successfully\n", stderr)
            } else {
                fputs("DEBUG: Failed to start media capture\n", stderr)
                "Failed to start capture".withCString { ptr in
                    exitCallback(ptr, context)
                }
            }
        } catch {
            fputs("DEBUG: Exception during startMediaCapture: \(error.localizedDescription)\n", stderr)
            error.localizedDescription.withCString { ptr in
                exitCallback(ptr, context)
            }
        }
    }
}

@_cdecl("stopMediaCapture")
public func stopMediaCapture(_ p: UnsafeMutableRawPointer, _ callback: StopCaptureCallback, _ context: UnsafeMutableRawPointer?) {
    fputs("DEBUG: stopMediaCapture called\n", stderr)
    
    let capture = Unmanaged<MediaCapture>.fromOpaque(p).takeUnretainedValue()
    let sendableCtx = MediaSendableContext(value: context)
    
    Task {
        let context = sendableCtx.value
        
        fputs("DEBUG: Stopping media capture\n", stderr)
        await capture.stopCapture()
        fputs("DEBUG: Media capture stopped successfully\n", stderr)
        
        callback(context)
    }
}