import Foundation
import CoreGraphics
import ScreenCaptureKit

/// 画面キャプチャと音声キャプチャで共通して利用するキャプチャターゲット構造体
public struct SharedCaptureTarget {  // CaptureTarget → SharedCaptureTargetに変更
    /// ウィンドウID（ウィンドウ固有の識別子）
    public let windowID: CGWindowID
    
    /// ディスプレイID（ディスプレイ固有の識別子）
    public let displayID: CGDirectDisplayID
    
    /// ウィンドウやアプリケーションのタイトル
    public let title: String?
    
    /// アプリケーションのバンドルID
    public let bundleID: String?
    
    /// ウィンドウやディスプレイの座標とサイズ情報
    public let frame: CGRect
    
    /// アプリケーション名
    public let applicationName: String?
    
    /// ウィンドウターゲットかどうか
    public var isWindow: Bool { windowID > 0 }
    
    /// ディスプレイターゲットかどうか
    public var isDisplay: Bool { displayID > 0 }
    
    /// イニシャライザ
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
    
    /// SCWindowからCaptureTargetを作成するファクトリメソッド
    public static func from(window: SCWindow) -> SharedCaptureTarget {
        return SharedCaptureTarget(
            windowID: window.windowID,
            title: window.title,
            bundleID: window.owningApplication?.bundleIdentifier,
            applicationName: window.owningApplication?.applicationName,
            frame: window.frame
        )
    }
    
    /// SCDisplayからCaptureTargetを作成するファクトリメソッド
    public static func from(display: SCDisplay) -> SharedCaptureTarget {
        return SharedCaptureTarget(
            displayID: display.displayID,
            title: "ディスプレイ \(display.displayID)",
            frame: CGRect(x: 0, y: 0, width: display.width, height: display.height)
        )
    }
}

extension SharedCaptureTarget {
    // ScreenCapture.CaptureTargetへの参照を完全修飾名で行う
    // 型の参照を修正
    public init(from enumTarget: ScreenCapture.CaptureTarget) {
        switch enumTarget {
        case .screen(let displayID):
            self.init(displayID: displayID)
        case .window(let windowID):
            self.init(windowID: windowID)
        case .application(let bundleID):
            self.init(bundleID: bundleID)
        case .entireDisplay:
            self.init()
        }
    }
    
    // 明確に返り値の型を指定
    public func toEnumTarget() -> ScreenCapture.CaptureTarget {
        if isWindow {
            return .window(windowID: windowID)
        } else if isDisplay {
            return .screen(displayID: displayID)
        } else if let bundleID = bundleID {
            return .application(bundleID: bundleID)
        } else {
            return .entireDisplay
        }
    }
}