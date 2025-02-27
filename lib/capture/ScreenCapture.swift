import Foundation
import CoreGraphics
import AVFoundation
import ScreenCaptureKit
import OSLog

// FrameData structure
public struct FrameData {
    public let data: Data
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let timestamp: Double
    public let pixelFormat: OSType  // Pixel format
}

public class ScreenCapture: NSObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "org.voibo.desktop-audio-capture", category: "ScreenCapture")
    private var stream: SCStream?
    private var streamOutput: ScreenCaptureOutput?
    private var running: Bool = false
    private var frameCallback: ((FrameData) -> Void)?
    private var errorCallback: ((String) -> Void)?
    
    // Capture quality settings
    public enum CaptureQuality: Int {
        case high = 0    // Original size
        case medium = 1  // 75% scale
        case low = 2     // 50% scale
        
        var scale: Double {
            switch self {
                case .high: return 1.0
                case .medium: return 0.75
                case .low: return 0.5
            }
        }
    }
    
    // Capture target types
    public enum CaptureTarget {
        case screen(displayID: CGDirectDisplayID)  // Specific screen
        case window(windowID: CGWindowID)          // Specific window
        case application(bundleID: String)         // Specific application
        case entireDisplay                         // Entire display (default)
    }
    
    // Structure representing an application and its associated windows
    public struct AppWindow: Identifiable, Hashable {
        public let id: CGWindowID
        public let owningApplication: SCRunningApplication?
        public let title: String?
        public let frame: CGRect
        
        public var displayName: String {
            return owningApplication?.applicationName ?? "Unknown Application"
        }
        
        public func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
        
        public static func == (lhs: AppWindow, rhs: AppWindow) -> Bool {
            return lhs.id == rhs.id
        }
    }
    
    // Get a list of available windows
    class func availableWindows() async throws -> [AppWindow] {
        // Check environment variable and use mock for testing
        if ProcessInfo.processInfo.environment["USE_MOCK_CAPTURE"] == "1" {
            // Add mock data
            return [
                AppWindow(
                    id: 1,
                    owningApplication: nil,
                    title: "Mock Window 1",
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600)
                ),
                AppWindow(
                    id: 2,
                    owningApplication: nil,
                    title: "Mock Window 2",
                    frame: CGRect(x: 100, y: 100, width: 800, height: 600)
                )
            ]
        }
        
        // Actual implementation (existing code)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        return content.windows.compactMap { window in
            let title = window.title
            let frame = window.frame
            
            return AppWindow(
                id: window.windowID,
                owningApplication: window.owningApplication,
                title: title,
                frame: frame
            )
        }.sorted { $0.displayName < $1.displayName }
    }
    
    public func startCapture(
        target: CaptureTarget = .entireDisplay,
        frameHandler: @escaping (FrameData) -> Void,
        errorHandler: ((String) -> Void)? = nil,
        framesPerSecond: Double = 1.0, // Support sub-integer frame rates
        quality: CaptureQuality = .high
    ) async throws -> Bool {
        if running {
            return false
        }
        
        frameCallback = frameHandler
        errorCallback = errorHandler
        
        // Create content filter based on capture target
        let filter = try await createContentFilter(for: target)
        
        // Create stream configuration
        let configuration = SCStreamConfiguration()
        
        // Set frame rate (support for low frame rates)
        if framesPerSecond >= 1.0 {
            // Normal frame rate (1fps or higher)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        } else {
            // Low-frequency capture (less than 1fps)
            let seconds = 1.0 / framesPerSecond
            // Use high-precision timescale to ensure accuracy
            configuration.minimumFrameInterval = CMTime(seconds: seconds, preferredTimescale: 600)
        }
        
        // Quality settings (resolution scaling)
        if quality != .high {
            // Get display resolution
            let mainDisplayID = CGMainDisplayID()
            let width = CGDisplayPixelsWide(mainDisplayID)
            let height = CGDisplayPixelsHigh(mainDisplayID)
            
            // Perform Double calculation and convert the result to Int
            let scaleFactor = Double(quality.scale)
            let scaledWidth = Int(Double(width) * scaleFactor)
            let scaledHeight = Int(Double(height) * scaleFactor)
            
            // Set size limits
            configuration.width = scaledWidth
            configuration.height = scaledHeight
        }

        // Cursor display settings
        configuration.showsCursor = true
        
        // Set capture output
        let output = ScreenCaptureOutput()
        output.frameHandler = { [weak self] (frameData) in
            self?.frameCallback?(frameData)
        }
        output.errorHandler = { [weak self] (error) in
            self?.errorCallback?(error)
        }
        
        streamOutput = output
        
        // Create stream
        stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        
        // Add output settings
        try stream?.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)
        
        // Start capture
        try await stream?.startCapture()
        
        running = true
        return true
    }
    
    private func createContentFilter(for target: CaptureTarget) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        switch target {
            case .screen(let displayID):
                if let display = content.displays.first(where: { $0.displayID == displayID }) {
                    return SCContentFilter(display: display, excludingWindows: [])
                } else {
                    throw NSError(domain: "ScreenCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Specified display not found"])
                }
                
            case .window(let windowID):
                if let window = content.windows.first(where: { $0.windowID == windowID }) {
                    return SCContentFilter(desktopIndependentWindow: window)
                } else {
                    throw NSError(domain: "ScreenCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Specified window not found"])
                }
                
            case .application(let bundleID):
                let appWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID }
                if !appWindows.isEmpty {
                    // Get the first window of the application
                    if let window = appWindows.first {
                        // Single window filter
                        return SCContentFilter(desktopIndependentWindow: window)
                    } else {
                        throw NSError(domain: "ScreenCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "Specified application window not found"])
                    }
                } else {
                    throw NSError(domain: "ScreenCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "Specified application window not found"])
                }
                
            case .entireDisplay:
                // Use the main display by default
                if let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first {
                    return SCContentFilter(display: mainDisplay, excludingWindows: [])
                } else {
                    throw NSError(domain: "ScreenCapture", code: 4, userInfo: [NSLocalizedDescriptionKey: "No available displays"])
                }
        }
    }
    
    public func stopCapture() async {
        if running {
            try? await stream?.stopCapture()
            stream = nil
            streamOutput = nil
            running = false
        }
    }
    
    public func isCapturing() -> Bool {
        return running
    }
    
    deinit {
        // Use weak reference to create Task
        let capturePtr = self.stream
        Task { [weak capturePtr] in
            if let stream = capturePtr {
                try? await stream.stopCapture()
            }
        }
        
        // Or avoid asynchronous processing in deinit and recommend explicit resource release
        // Avoid using async in deinit
        // stream = nil
        // streamOutput = nil
        // running = false
    }
    
    // Deprecate existing enum CaptureTarget (keep for backward compatibility)
    @available(*, deprecated, message: "Use global CaptureTarget struct instead")
    public enum CaptureTargetLegacy {
        case screen(displayID: CGDirectDisplayID)
        case window(windowID: CGWindowID)
        case application(bundleID: String)
        case entireDisplay
    }
}

// Class implementing the SCStreamOutput protocol
private class ScreenCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let logger = Logger(subsystem: "org.voibo.desktop-audio-capture", category: "ScreenCaptureOutput")
    var frameHandler: ((FrameData) -> Void)?
    var errorHandler: ((String) -> Void)?
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        
        let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        
        // Process differently for YUV (420v) and RGB formats
        let timestamp = CACurrentMediaTime()
        var frameData: FrameData
        
        if pixelFormat == 0x34323076 { // '420v' YUV format
            // Convert from YUV to RGB using CIImage
            CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
            
            // Create CIImage and convert from YUV to RGB
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            
            // Convert CIImage to CGImage
            let context = CIContext(options: nil)
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
                logger.error("Failed to convert CIImage to CGImage")
                return
            }
            
            // Get bitmap data from CGImage
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            let bitsPerComponent = 8
            let bytesPerRow = width * 4
            
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(data: nil,
                                         width: width,
                                         height: height,
                                         bitsPerComponent: bitsPerComponent,
                                         bytesPerRow: bytesPerRow,
                                         space: colorSpace,
                                         bitmapInfo: bitmapInfo.rawValue) else {
                logger.error("Failed to create CGContext")
                return
            }
            
            // Draw CGImage
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            
            // Get bitmap data
            guard let data = context.data else {
                logger.error("Failed to get bitmap data")
                return
            }
            
            // Create Data object
            let rgbData = Data(bytes: data, count: bytesPerRow * height)
            
            // Create FrameData with RGB data
            frameData = FrameData(
                data: rgbData,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                timestamp: timestamp,
                pixelFormat: kCVPixelFormatType_32BGRA // Converted format
            )
            
            #if DEBUG
            logger.debug("Converted from YUV to RGB: width=\(width), height=\(height), bytesPerRow=\(bytesPerRow)")
            #endif
        } else {
            #if DEBUG
            // Check pixel format and log
            let formatName: String
            switch pixelFormat {
            case kCVPixelFormatType_32BGRA:
                formatName = "kCVPixelFormatType_32BGRA"
            case kCVPixelFormatType_32RGBA:
                formatName = "kCVPixelFormatType_32RGBA"
            case kCVPixelFormatType_32ARGB:
                formatName = "kCVPixelFormatType_32ARGB"
            case kCVPixelFormatType_32ABGR:
                formatName = "kCVPixelFormatType_32ABGR"
            default:
                formatName = "Unknown format: \(pixelFormat)"
            }
            logger.debug("Pixel format: \(formatName)")

            // Output detailed CVPixelBuffer information
            let planeCount = CVPixelBufferGetPlaneCount(imageBuffer)
            logger.debug("Plane count: \(planeCount)")
            #endif
              
            // Modified CVPixelFormatDescription part
            let pixelFormatType = CVPixelBufferGetPixelFormatType(imageBuffer)
            #if DEBUG
            logger.debug("Format information: \(pixelFormatType)")
            #endif
            
            // Existing code...
            CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
            
            let width = CVPixelBufferGetWidth(imageBuffer)
            let height = CVPixelBufferGetHeight(imageBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)

            // --- Debugging ---
            // Adjust if bytesPerRow is different from the expected value
            let expectedBytesPerRow = width * 4 // Assuming 32 bits/pixel
            if bytesPerRow != expectedBytesPerRow {
                logger.warning("bytesPerRow(\(bytesPerRow)) is different from the expected value(\(expectedBytesPerRow)).")
            }
            
            // Check alignment
            #if DEBUG
            logger.debug("Width: \(width), Height: \(height), bytesPerRow: \(bytesPerRow)")
            #endif
            
            guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else { return }
            
            // Realign data if necessary before constructing frame data
            let data: Data
            if bytesPerRow == width * 4 {
                // Ideal case: no padding
                data = Data(bytes: baseAddress, count: bytesPerRow * height)
            } else {
                // With padding: copy row by row
                var newData = Data(capacity: width * height * 4)
                for y in 0..<height {
                    let srcRow = baseAddress.advanced(by: y * bytesPerRow)
                    let actualRowBytes = min(width * 4, bytesPerRow)
                    newData.append(Data(bytes: srcRow, count: actualRowBytes))
                    
                    // Fill the remaining bytes with 0 (if necessary)
                    if actualRowBytes < width * 4 {
                        let padding = [UInt8](repeating: 0, count: width * 4 - actualRowBytes)
                        newData.append(contentsOf: padding)
                    }
                }
                data = newData
                #if DEBUG
                logger.debug("Data realigned: original bytesPerRow=\(bytesPerRow), new bytesPerRow=\(width * 4)")
                #endif
            }
            let timestamp = CACurrentMediaTime()
            
            // Construct frame data
            frameData = FrameData(
                data: data,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                timestamp: timestamp,
                pixelFormat: pixelFormat
            )
        }
        
        // Call callback
        DispatchQueue.main.async { [weak self] in
            self?.frameHandler?(frameData)
        }
    }
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let errorMessage = "Capture stream stopped: \(error.localizedDescription)"
        errorHandler?(errorMessage)
    }
}
