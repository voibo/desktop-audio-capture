# ScreenCapture Xcode Project (Sample Implementation)

This project provides a sample implementation for screen and audio capture on macOS. It is intended for demonstration and testing purposes within the larger open-source project.

## Requirements

- macOS 12.3 or later
- Xcode 13.0 or later
- Swift 5.6 or later

## Project Structure

- `ScreenCaptureSample.xcodeproj`: Xcode project file
- `ScreenCaptureSample`: Application target
- `ScreenCaptureSampleTests`: Test target
- `lib/capture`: Capture-related source code
  - `ScreenCapture.swift`: Main class for screen capture
  - `AudioCapture.swift`: Main class for audio capture
  - `SharedCaptureTarget.swift`: Common target definition for screen and audio capture
  - `CaptureTargetConverter.swift`: Capture target conversion utility
- `tests/mac/ScreenCaptureSample/ScreenCaptureSampleTests`: Test code

## Build and Run

1.  Open `ScreenCaptureSample.xcodeproj` in Xcode.
2.  Select the target (`ScreenCaptureSample` or `ScreenCaptureSampleTests`).
3.  Build the project (`Cmd + B`).
4.  Run the application (`Cmd + R`).

## Run Tests

1.  Select the `ScreenCaptureSampleTests` target in Xcode.
2.  Run the tests (`Cmd + U`).

## Dependencies

- ScreenCaptureKit
- AVFoundation
- CoreGraphics

## Important Notes

- Screen recording permission is required in System Preferences for screen capture.
- Microphone permission is required in System Preferences for audio capture.

## License

This project is provided under the MIT License. See the LICENSE file for details.
