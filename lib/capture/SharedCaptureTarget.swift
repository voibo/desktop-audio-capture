import Foundation
import CoreGraphics
import ScreenCaptureKit

/// A structure representing a shared capture target for both screen and audio capture.
public struct SharedCaptureTarget {
    /// The ID of the window (unique identifier for a window).
    public let windowID: CGWindowID
    
    /// The ID of the display (unique identifier for a display).
    public let displayID: CGDirectDisplayID
    
    /// The title of the window or application.
    public let title: String?
    
    /// The bundle ID of the application.
    public let bundleID: String?
    
    /// The frame (coordinates and size) of the window or display.
    public let frame: CGRect
    
    /// The name of the application.
    public let applicationName: String?
    
    /// A Boolean value indicating whether the target is a window.
    public var isWindow: Bool { windowID > 0 }
    
    /// A Boolean value indicating whether the target is a display.
    public var isDisplay: Bool { displayID > 0 }
    
    /// Initializes a new capture target.
    public init(
        windowID: CGWindowID = 0, 
        displayID: CGDirectDisplayID = 0, 
        title: String? = nil, 
        bundleID: String? = nil, 
        applicationName: String? = nil,
        frame: CGRect = .zero
    ) {
        self.windowID = windowID
        self.displayID = displayID
        self.title = title
        self.bundleID = bundleID
        self.applicationName = applicationName
        self.frame = frame
    }
    
    /// Creates a `SharedCaptureTarget` from an `SCWindow`.
    public static func from(window: SCWindow) -> SharedCaptureTarget {
        return SharedCaptureTarget(
            windowID: window.windowID,
            title: window.title,
            bundleID: window.owningApplication?.bundleIdentifier,
            applicationName: window.owningApplication?.applicationName,
            frame: window.frame
        )
    }
    
    /// Creates a `SharedCaptureTarget` from an `SCDisplay`.
    public static func from(display: SCDisplay) -> SharedCaptureTarget {
        return SharedCaptureTarget(
            displayID: display.displayID,
            title: "Display \(display.displayID)",
            frame: CGRect(x: 0, y: 0, width: display.width, height: display.height)
        )
    }
}