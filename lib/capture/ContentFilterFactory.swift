import Foundation
import ScreenCaptureKit

public class ContentFilterFactory {
    // CaptureTargetをSharedCaptureTargetに変更
    public static func createFilter(from target: SharedCaptureTarget) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        if target.isDisplay {
            guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
                throw NSError(domain: "ContentFilterFactory", code: 1, userInfo: [NSLocalizedDescriptionKey: "指定されたディスプレイが見つかりません"])
            }
            
            return SCContentFilter(display: display, excludingWindows: [])
        } else if target.isWindow {
            guard let window = content.windows.first(where: { $0.windowID == target.windowID }) else {
                throw NSError(domain: "ContentFilterFactory", code: 2, userInfo: [NSLocalizedDescriptionKey: "指定されたウィンドウが見つかりません"])
            }
            
            return SCContentFilter(desktopIndependentWindow: window)
        } else if let bundleID = target.bundleID {
            let appWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID }
            
            guard let window = appWindows.first else {
                throw NSError(domain: "ContentFilterFactory", code: 3, userInfo: [NSLocalizedDescriptionKey: "指定されたアプリケーションのウィンドウが見つかりません"])
            }
            
            return SCContentFilter(desktopIndependentWindow: window)
        } else {
            // デフォルト：メインディスプレイ
            guard let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw NSError(domain: "ContentFilterFactory", code: 4, userInfo: [NSLocalizedDescriptionKey: "利用可能なディスプレイがありません"])
            }
            
            return SCContentFilter(display: mainDisplay, excludingWindows: [])
        }
    }
}
