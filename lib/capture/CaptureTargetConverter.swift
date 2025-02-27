import Foundation
import CoreGraphics
import ScreenCaptureKit

/// A utility class for converting between SharedCaptureTarget and ScreenCapture.CaptureTarget.
/// This separates conversion logic to avoid circular references.
public struct CaptureTargetConverter {
    /// Converts a SharedCaptureTarget to a ScreenCapture.CaptureTarget.
    public static func toScreenCaptureTarget(_ shared: SharedCaptureTarget) -> ScreenCapture.CaptureTarget {
        if shared.isWindow {
            return .window(windowID: shared.windowID)
        } else if shared.isDisplay {
            return .screen(displayID: shared.displayID)
        } else if let bundleID = shared.bundleID {
            return .application(bundleID: bundleID)
        } else {
            return .entireDisplay
        }
    }
    
    /// Converts a ScreenCapture.CaptureTarget to a SharedCaptureTarget.
    public static func fromScreenCaptureTarget(_ target: ScreenCapture.CaptureTarget) -> SharedCaptureTarget {
        switch target {
        case .screen(let displayID):
            return SharedCaptureTarget(displayID: displayID)
        case .window(let windowID):
            return SharedCaptureTarget(windowID: windowID)
        case .application(let bundleID):
            return SharedCaptureTarget(bundleID: bundleID)
        case .entireDisplay:
            return SharedCaptureTarget()
        }
    }
    
    /// Creates an SCContentFilter from a SharedCaptureTarget.
    public static func createContentFilter(from target: SharedCaptureTarget) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        if target.isDisplay {
            guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
                throw NSError(domain: "CaptureTargetConverter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Specified display not found"])
            }
            
            return SCContentFilter(display: display, excludingWindows: [])
        } else if target.isWindow {
            guard let window = content.windows.first(where: { $0.windowID == target.windowID }) else {
                throw NSError(domain: "CaptureTargetConverter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Specified window not found"])
            }
            
            return SCContentFilter(desktopIndependentWindow: window)
        } else if let bundleID = target.bundleID {
            let appWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID }
            
            guard let window = appWindows.first else {
                throw NSError(domain: "CaptureTargetConverter", code: 3, userInfo: [NSLocalizedDescriptionKey: "Specified application window not found"])
            }
            
            return SCContentFilter(desktopIndependentWindow: window)
        }
        
        // Default: Main display
        guard let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw NSError(domain: "CaptureTargetConverter", code: 4, userInfo: [NSLocalizedDescriptionKey: "No available displays"])
        }
        
        return SCContentFilter(display: mainDisplay, excludingWindows: [])
    }
}