//
//  MediaCaptureTestApp.swift
//  MediaCaptureTest
//
//  Created by Nobuhiro Hayashi on 2025/02/28.
//

import SwiftUI

@main
struct MediaCaptureTestApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar) // モダンなウィンドウスタイルを適用
    }
}
