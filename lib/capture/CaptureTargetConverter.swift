import Foundation
import CoreGraphics
import ScreenCaptureKit

/// SharedCaptureTargetとScreenCapture.CaptureTarget間の変換を行うユーティリティクラス
/// 循環参照を回避するために変換ロジックを分離しています
public struct CaptureTargetConverter {
    /// SharedCaptureTargetからScreenCapture.CaptureTargetへの変換
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
    
    /// ScreenCapture.CaptureTargetからSharedCaptureTargetへの変換
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
    
    /// SCContentFilterをSharedCaptureTargetから作成
    public static func createContentFilter(from target: SharedCaptureTarget, excludeCurrentApp: Bool = false) async throws -> SCContentFilter? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        if target.isDisplay {
            guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
                throw NSError(domain: "CaptureTargetConverter", code: 1, userInfo: [NSLocalizedDescriptionKey: "指定されたディスプレイが見つかりません"])
            }
            
            var excludedApps = [SCRunningApplication]()
            if excludeCurrentApp {
                excludedApps = content.applications.filter { app in
                    Bundle.main.bundleIdentifier == app.bundleIdentifier
                }
            }
            
            return SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        } else if target.isWindow {
            guard let window = content.windows.first(where: { $0.windowID == target.windowID }) else {
                throw NSError(domain: "CaptureTargetConverter", code: 2, userInfo: [NSLocalizedDescriptionKey: "指定されたウィンドウが見つかりません"])
            }
            
            return SCContentFilter(desktopIndependentWindow: window)
        } else if let bundleID = target.bundleID {
            let appWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID }
            
            guard let window = appWindows.first else {
                throw NSError(domain: "CaptureTargetConverter", code: 3, userInfo: [NSLocalizedDescriptionKey: "指定されたアプリケーションのウィンドウが見つかりません"])
            }
            
            return SCContentFilter(desktopIndependentWindow: window)
        } else {
            // デフォルト：メインディスプレイ
            guard let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw NSError(domain: "CaptureTargetConverter", code: 4, userInfo: [NSLocalizedDescriptionKey: "利用可能なディスプレイがありません"])
            }
            
            return SCContentFilter(display: mainDisplay, excludingWindows: [])
        }
    }
}