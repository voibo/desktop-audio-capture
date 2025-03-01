import AVFoundation
import CaptureC
import Foundation
import ScreenCaptureKit

struct SendableValue<T>: @unchecked Sendable {
    let value: T
}

public typealias EnumerateDesktopWindowsCallback = @convention(c) (
    UnsafePointer<DisplayInfo>?, Int32, UnsafePointer<WindowInfo>?, Int32, UnsafePointer<Int8>?, UnsafeRawPointer?
) -> Void

@_cdecl("enumerateDesktopWindows")
public func enumerateDesktopWindows(_ callback: EnumerateDesktopWindowsCallback, _ context: UnsafeRawPointer?) {
    let sendableCtx = SendableValue(value: context)

    Task {
        let context = sendableCtx.value

        do {
            let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            let availableDisplays = availableContent.displays
            let availableWindows = filterWindows(availableContent.windows)

            var displays = [DisplayInfo]()
            for d in availableDisplays {
                displays.append(DisplayInfo(displayID: d.displayID))
            }

            var windows = [WindowInfo]()
            for w in availableWindows {
                windows.append(WindowInfo(windowID: w.windowID, title: w.title == nil ? nil : strdup(w.title)))
            }
            defer {
                for w in windows {
                    free(w.title)
                }
            }

            displays.withUnsafeBufferPointer { dp in
                windows.withUnsafeBufferPointer { wp in
                    callback(dp.baseAddress, Int32(displays.count), wp.baseAddress, Int32(windows.count), Optional<UnsafePointer<Int8>>.none, context)
                }
            }
        } catch {
            error.localizedDescription.withCString { ptr in
                callback(nil, 0, nil, 0, ptr, context)
            }
        }
    }
}
func filterWindows(_ windows: [SCWindow]) -> [SCWindow] {
    windows
        // Sort the windows by app name.
        .sorted { $0.owningApplication?.applicationName ?? "" < $1.owningApplication?.applicationName ?? "" }
        // Remove windows that don't have an associated .app bundle.
        .filter { $0.owningApplication != nil && $0.owningApplication?.applicationName != "" }
        // Remove this app's window from the list.
        .filter { $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }
}

@_cdecl("createCapture")
public func createCapture() -> UnsafeMutableRawPointer {
    let capture = AudioCapture()
    return Unmanaged.passRetained(capture).toOpaque()
}

@_cdecl("destroyCapture")
public func destroyCapture(_ p: UnsafeMutableRawPointer) {
    Unmanaged<AudioCapture>.fromOpaque(p).release()
}

public typealias StartCaptureDataCallback = @convention(c) (Int32, Int32, UnsafePointer<Float32>?, Int32, UnsafeMutableRawPointer?) -> Void
public typealias StartCaptureExitCallback = @convention(c) (UnsafePointer<Int8>?, UnsafeMutableRawPointer?) -> Void

@_cdecl("startCapture")
public func startCapture(
    _ p: UnsafeMutableRawPointer,
    _ config: CaptureConfig,
    _ dataCallback: StartCaptureDataCallback,
    _ exitCallback: StartCaptureExitCallback,
    _ context: UnsafeMutableRawPointer?
) {
    let capture = Unmanaged<AudioCapture>.fromOpaque(p).takeUnretainedValue()
    let sendableCtx = SendableValue(value: context)

    Task {
        let context = sendableCtx.value

        do {
            let streamConfig = SCStreamConfiguration()
            streamConfig.capturesAudio = true
            streamConfig.excludesCurrentProcessAudio = true
            streamConfig.sampleRate = Int(config.sampleRate)
            streamConfig.channelCount = Int(config.channels)

            guard let filter = try await createContentFilter(displayID: config.displayID, windowID: config.windowID, isAppExcluded: true) else {
                "neither a display nor a window is specified.".withCString { ptr in
                    exitCallback(ptr, context)
                }
                return
            }

            guard
                let expectedFormat = AVAudioFormat(
                    commonFormat: AVAudioCommonFormat.pcmFormatFloat32,
                    sampleRate: Double(config.sampleRate),
                    channels: AVAudioChannelCount(config.channels),
                    interleaved: true
                )
            else {
                "failed to initialize audio format".withCString { ptr in
                    exitCallback(ptr, context)
                }
                return
            }

            var converter: AVAudioConverter?
            for try await buffer in capture.startCapture(configuration: streamConfig, filter: filter) {
                if converter == nil || !converter!.inputFormat.isEqual(buffer.format) {
                    converter = AVAudioConverter(from: buffer.format, to: expectedFormat)
                }
                guard let copiedConverter = converter else {
                    "failed to initialize audio converter".withCString { ptr in
                        exitCallback(ptr, context)
                    }
                    return
                }

                let outputFrameLength = buffer.frameLength * UInt32(expectedFormat.sampleRate) / UInt32(buffer.format.sampleRate)
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: expectedFormat, frameCapacity: outputFrameLength) else { continue }

                var error: NSError? = nil
                copiedConverter.convert(to: outputBuffer, error: &error) { _, inputStatus in
                    inputStatus.pointee = .haveData
                    return buffer
                }
                if let err = error {
                    err.localizedDescription.withCString { ptr in
                        exitCallback(ptr, context)
                    }
                    return
                }

                guard let floatData = outputBuffer.floatChannelData else { continue }
                dataCallback(config.channels, config.sampleRate, UnsafePointer(floatData[0]), Int32(outputBuffer.frameLength), context)
            }
            exitCallback(nil, context)
        } catch {
            error.localizedDescription.withCString { ptr in
                exitCallback(ptr, context)
            }
        }
    }
}

private func createContentFilter(displayID: UInt32, windowID: UInt32, isAppExcluded: Bool) async throws -> SCContentFilter? {
    let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let availableDisplays = availableContent.displays
    let availableWindows = filterWindows(availableContent.windows)
    let availableApps = availableContent.applications

    var filter: SCContentFilter
    if displayID > 0 {
        guard let display = findDisplay(availableDisplays, displayID) else { return nil }
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
        guard let window = findWindow(availableWindows, windowID) else { return nil }
        filter = SCContentFilter(desktopIndependentWindow: window)
    } else {
        return nil
    }

    return filter
}

private func findDisplay(_ displays: [SCDisplay], _ displayID: UInt32) -> SCDisplay? {
    for display in displays {
        if display.displayID == displayID {
            return display
        }
    }

    return nil
}

private func findWindow(_ windows: [SCWindow], _ windowID: UInt32) -> SCWindow? {
    for window in windows {
        if window.windowID == windowID {
            return window
        }
    }

    return nil
}

public typealias StopCaptureCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void

@_cdecl("stopCapture")
public func stopCapture(_ p: UnsafeMutableRawPointer, _ callback: StopCaptureCallback, _ context: UnsafeMutableRawPointer?) {
    let capture = Unmanaged<AudioCapture>.fromOpaque(p).takeUnretainedValue()
    let sendableCtx = SendableValue(value: context)

    Task {
        let context = sendableCtx.value

        await capture.stopCapture()
        callback(context)
    }
}