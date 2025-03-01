import SwiftUI

@main
struct MediaCaptureTestApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 800)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
