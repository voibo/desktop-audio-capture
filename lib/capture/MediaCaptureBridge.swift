import AVFoundation
import CaptureC
import Foundation
import ScreenCaptureKit

#if os(macOS)
import AppKit

class AppDelegateWorkaround: NSObject {
    static let shared = AppDelegateWorkaround()
    
    override init() {
        super.init()
        NSApp.setActivationPolicy(.prohibited)
    }
}
#endif

private struct MediaSendableContext<T>: @unchecked Sendable {
    let value: T
}

fileprivate func filterMediaWindows(_ windows: [SCWindow]) -> [SCWindow] {
    windows
        .sorted { $0.owningApplication?.applicationName ?? "" < $1.owningApplication?.applicationName ?? "" }
        .filter { $0.owningApplication != nil && $0.owningApplication?.applicationName != "" }
        .filter { $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }
}

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

// Bridge functions to C/C++ layer

@_cdecl("createMediaCapture")
public func createMediaCapture() -> UnsafeMutableRawPointer {
    #if os(macOS)
    // fputs("DEBUG: Using headless mode for MediaCapture\n", stderr)
    #endif
    
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
    // fputs("DEBUG: enumerateMediaCaptureTargets called with type \(type)\n", stderr)

    struct TargetResult {
        var targets: [MediaCaptureTargetC]?
        var error: String?
    }
    
    var result: TargetResult? = nil
    let semaphore = DispatchSemaphore(value: 0)
    
    Task {
        do {
            let targetType: MediaCapture.CaptureTargetType
            switch type {
            case 0: targetType = .all
            case 1: targetType = .screen
            case 2: targetType = .window
            default: targetType = .all
            }

            // fputs("DEBUG: Fetching available targets of type \(targetType)...\n", stderr)

            let availableTargets = try await MediaCapture.availableCaptureTargets(ofType: targetType)
            // fputs("DEBUG: Found \(availableTargets.count) available targets\n", stderr)

            var targets = [MediaCaptureTargetC]()

            for target in availableTargets {
                var cTarget = MediaCaptureTargetC()
                cTarget.isDisplay = target.isDisplay ? 1 : 0
                cTarget.isWindow = target.isWindow ? 1 : 0
                cTarget.displayID = target.displayID
                cTarget.windowID = target.windowID
                cTarget.width = Int32(target.frame.width)
                cTarget.height = Int32(target.frame.height)

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

            result = TargetResult(targets: targets, error: nil)
            
        } catch {
            fputs("DEBUG: Error during target enumeration: \(error.localizedDescription)\n", stderr)
            result = TargetResult(targets: nil, error: error.localizedDescription)
        }
        
        semaphore.signal()
    }
    
    // Wait for async operation with timeout
    if semaphore.wait(timeout: .now() + 10) == .timedOut {
        fputs("DEBUG: Target enumeration timed out\n", stderr)
        "Operation timed out".withCString { ptr in
            callback(nil, 0, ptr, context)
        }
        return
    }
    
    let executeCallbacks = {
        guard let result = result else {
            "Unknown error".withCString { ptr in
                callback(nil, 0, ptr, context)
            }
            return
        }
        
        if let error = result.error {
            error.withCString { ptr in
                callback(nil, 0, ptr, context)
            }
            return
        }
        
        if let targets = result.targets, !targets.isEmpty {
            let targetsCopy = targets
            
            targetsCopy.withUnsafeBufferPointer { ptr in
                callback(ptr.baseAddress, Int32(targetsCopy.count), nil, context)
            }
            
            for target in targetsCopy {
                if let title = target.title {
                    free(title)
                }
                if let appName = target.appName {
                    free(appName)
                }
            }
        } else {
            callback(nil, 0, nil, context)
        }
    }
    
    if Thread.isMainThread {
        executeCallbacks()
    } else {
        DispatchQueue.main.async {
            executeCallbacks()
        }
    }
}

// C callback type definitions
public typealias MediaCaptureDataCallback = @convention(c) (
    UnsafePointer<UInt8>?, Int32, Int32, Int32, UnsafePointer<Int8>?, UnsafePointer<Int8>?, Int32, UnsafeRawPointer?
) -> Void

public typealias MediaCaptureAudioDataCallback = @convention(c) (
    Int32, Int32, UnsafePointer<Float32>?, Int32, UnsafeRawPointer?
) -> Void

public typealias MediaCaptureAudioDataExCallback = @convention(c) (
    UnsafePointer<AudioFormatInfoC>?, UnsafePointer<UnsafePointer<Float32>?>?, Int32, UnsafeRawPointer?
) -> Void

public typealias MediaCaptureExitCallback = @convention(c) (
    UnsafePointer<Int8>?, UnsafeRawPointer?
) -> Void

@_cdecl("startMediaCapture")
public func startMediaCapture(
    _ p: UnsafeMutableRawPointer,
    _ config: MediaCaptureConfigC,
    _ videoCallback: MediaCaptureDataCallback,
    _ audioCallback: MediaCaptureAudioDataCallback,
    _ exitCallback: MediaCaptureExitCallback,
    _ context: UnsafeMutableRawPointer?
) {
    // fputs("DEBUG: startMediaCapture called\n", stderr)

    if p == UnsafeMutableRawPointer(bitPattern: 0) {
        fputs("ERROR: Invalid MediaCapture instance pointer\n", stderr)
        "Invalid MediaCapture instance".withCString { ptr in
            exitCallback(ptr, context)
        }
        return
    }

    let capture = Unmanaged<MediaCapture>.fromOpaque(p).takeUnretainedValue()

    let sendableCtx = MediaSendableContext(value: context)

    Task {
        let context = sendableCtx.value

        do {
            let quality = MediaCapture.CaptureQuality(rawValue: Int(config.quality)) ?? .medium

            // fputs("DEBUG: Configured quality: \(quality)\n", stderr)

            if config.displayID == 0 && config.windowID == 0 && config.bundleID == nil {
                fputs("DEBUG: No valid capture target specified\n", stderr)
                "No valid capture target specified".withCString { ptr in
                    exitCallback(ptr, context)
                }
                return
            }

            var target: MediaCaptureTarget?

            if config.displayID > 0 {
                // fputs("DEBUG: Finding display with ID \(config.displayID)\n", stderr)
                let targets = try await MediaCapture.availableCaptureTargets(ofType: .screen)
                target = targets.first { $0.displayID == config.displayID }

                if target == nil {
                    fputs("DEBUG: Display with ID \(config.displayID) not found\n", stderr)
                }
            } else if config.windowID > 0 {
                // fputs("DEBUG: Finding window with ID \(config.windowID)\n", stderr)
                let targets = try await MediaCapture.availableCaptureTargets(ofType: .window)
                target = targets.first { $0.windowID == config.windowID }

                if target == nil {
                    fputs("DEBUG: Window with ID \(config.windowID) not found\n", stderr)
                }
            } else if let bundleID = config.bundleID {
                // fputs("DEBUG: Finding app with bundle ID \(String(cString: bundleID))\n", stderr)
                let targets = try await MediaCapture.availableCaptureTargets(ofType: .window)
                let bundleIDStr = String(cString: bundleID)
                target = targets.first {
                    if let appName = $0.applicationName {
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

            /*
            let targetDesc = captureTarget.isDisplay ?
                "Display ID=\(captureTarget.displayID)" :
                "Window ID=\(captureTarget.windowID)" +
                (captureTarget.title != nil ? ", Title=\"\(captureTarget.title!)\"" : "") +
                (captureTarget.applicationName != nil ? ", App=\"\(captureTarget.applicationName!)\"" : "")
            fputs("DEBUG: Starting capture with target: \(targetDesc), Size=\(Int(captureTarget.frame.width))x\(Int(captureTarget.frame.height))\n", stderr)
            */

            let success = try await capture.startCapture(
                target: captureTarget,
                mediaHandler: { media in
                    autoreleasepool {
                        if let videoBuffer = media.videoBuffer,
                           let videoInfo = media.metadata.videoInfo {

                            let dataCopy = Data(videoBuffer)
                            
                            dataCopy.withUnsafeBytes { buffer in
                                guard let baseAddress = buffer.baseAddress else { return }
                                
                                let bufferSize = buffer.count
                                let formatString = media.metadata.videoInfo?.format ?? "jpeg"
                                
                                let timestampMillis = Int64(Date().timeIntervalSince1970 * 1000)
                                let timestampStr = "\(timestampMillis)"
                                
                                timestampStr.withCString { timestampPtr in
                                    formatString.withCString { formatPtr in
                                        videoCallback(
                                            baseAddress.assumingMemoryBound(to: UInt8.self),
                                            Int32(videoInfo.width),
                                            Int32(videoInfo.height),
                                            Int32(videoInfo.bytesPerRow),
                                            timestampPtr,
                                            formatPtr,
                                            Int32(bufferSize),
                                            context
                                        )
                                    }
                                }
                            }
                        }

                        if let audioBuffer = media.audioBuffer,
                           let audioInfo = media.metadata.audioInfo {

                            audioBuffer.withUnsafeBytes { buffer in
                                guard let baseAddress = buffer.baseAddress else {
                                    fputs("DEBUG: Failed to get audio buffer base address\n", stderr)
                                    return
                                }

                                let floatPtr = baseAddress.assumingMemoryBound(to: Float32.self)

                                audioCallback(
                                    Int32(audioInfo.channelCount),
                                    Int32(audioInfo.sampleRate),
                                    floatPtr,
                                    Int32(audioInfo.frameCount),
                                    context
                                )
                            }
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
                quality: quality,
                audioSampleRate: Int(config.audioSampleRate),
                audioChannelCount: Int(config.audioChannels),
                isElectron: config.isElectron != 0
            )

            // Setup timeout to detect start failure
            let startTimeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000) // 5-second timeout
                    fputs("WARN: Media capture start timeout\n", stderr)
                    "Capture start operation timed out".withCString { ptr in
                        exitCallback(ptr, context)
                    }
                } catch {
                    // Task canceled - startup succeeded
                }
            }

            if success {
                startTimeoutTask.cancel()
                // fputs("DEBUG: Media capture started successfully\n", stderr)
            } else {
                startTimeoutTask.cancel()
                fputs("DEBUG: Failed to start media capture\n", stderr)
                "Failed to start capture".withCString { ptr in
                    exitCallback(ptr, context)
                }
            }
        } catch {
            let detailedError = "Exception during startMediaCapture: \(error.localizedDescription), \((error as NSError).userInfo)"
            fputs("DEBUG: \(detailedError)\n", stderr)
            detailedError.withCString { ptr in
                exitCallback(ptr, context)
            }

            Task {
                await capture.stopCapture()
                // fputs("DEBUG: Capture resources cleaned up\n", stderr)
            }
        }
    }
}

@_cdecl("stopMediaCapture")
public func stopMediaCapture(_ p: UnsafeMutableRawPointer, _ callback: StopCaptureCallback, _ context: UnsafeMutableRawPointer?) {
    // fputs("DEBUG: stopMediaCapture called\n", stderr)

    let capture = Unmanaged<MediaCapture>.fromOpaque(p).takeUnretainedValue()

    if let ctx = context {
        callback(ctx)
    }

    Task {
        // fputs("DEBUG: Swift stopping media capture asynchronously\n", stderr)
        do {
            await capture.stopCapture()
            // fputs("DEBUG: Media capture stopped successfully\n", stderr)
        }
    }
}