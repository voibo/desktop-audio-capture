# Desktop Media Capture

Native Node.js module for capturing desktop audio and video on macOS and Windows.

> **IMPORTANT**: `AudioCapture` class is now deprecated. Please use `MediaCapture` instead, which provides both audio and video capture capabilities.

## Features

- Capture both audio and video from desktop screens and application windows
- High-performance native implementation
- Support for both macOS (Apple Silicon) and Windows
- Electron application support
- Event-based API for real-time processing

## Installation

```bash
npm install @voibo/desktop-media-capture
```

## Compatibility

- **macOS**: Apple Silicon (ARM64) devices
- **Windows**: 64-bit systems

## Basic Usage

```javascript
import {
  MediaCapture,
  MediaCaptureQuality,
  MediaCaptureTargetType,
} from "@voibo/desktop-audio-capture";

// Check if platform is supported
if (!MediaCapture.isSupported()) {
  console.error("MediaCapture is not supported on this platform");
  process.exit(1);
}

// Create a new capture instance
const capture = new MediaCapture();

// Set up event handlers
capture.on("video-frame", (frame) => {
  console.log(`Received video frame: ${frame.width}x${frame.height}`);
  // Process frame.data (Uint8Array) as needed
});

capture.on("audio-data", (audioData, sampleRate, channels) => {
  console.log(
    `Received audio data: ${audioData.length} samples, ${channels} channels at ${sampleRate}Hz`
  );
  // Process audioData (Float32Array) as needed
});

capture.on("error", (error) => {
  console.error("Capture error:", error);
});

// List available screen capture targets
const targets = await MediaCapture.enumerateMediaCaptureTargets(
  MediaCaptureTargetType.Screen
);
console.log("Available capture targets:", targets);

// Configure and start capture
capture.startCapture({
  displayId: targets[0].displayId, // First available display
  frameRate: 10, // Frames per second
  quality: MediaCaptureQuality.Medium,
  audioSampleRate: 44100,
  audioChannels: 2,
  isElectron: false, // Set to true for Electron apps
});

// Stop capture when done
setTimeout(async () => {
  await capture.stopCapture();
  console.log("Capture stopped");
}, 10000); // Capture for 10 seconds
```

## API Reference

### `MediaCapture` Class

#### Static Methods

- `MediaCapture.enumerateMediaCaptureTargets([type])`: Returns a promise with an array of available capture targets
- `MediaCapture.isSupported()`: Checks if MediaCapture is supported on the current platform

#### Instance Methods

- `startCapture(config)`: Starts capturing with the specified configuration
- `stopCapture()`: Stops the current capture and returns a Promise

#### Events

- `'video-frame'`: Emitted when a new video frame is available (JPEG format)
- `'audio-data'`: Emitted when new audio data is available
- `'error'`: Emitted when an error occurs
- `'exit'`: Emitted when the capture process exits

### Configuration Options

```typescript
interface MediaCaptureConfig {
  frameRate: number; // Video frame rate
  quality: number; // Using MediaCaptureQuality enum (High/Medium/Low)
  // High=90%, Medium=75%, Low=50% JPEG quality on both platforms
  qualityValue?: number; // Precise JPEG quality value (0-100)
  // Overrides quality enum if specified (works on both platforms)
  audioSampleRate: number; // Audio sample rate in Hz
  audioChannels: number; // Number of audio channels
  displayId?: number; // ID of display to capture
  windowId?: number; // ID of window to capture
  bundleId?: string; // macOS bundle ID
  isElectron?: boolean; // Set to true for Electron apps
}
```

### `AudioCapture` Class (DEPRECATED)

> **DEPRECATED**: The `AudioCapture` class is deprecated and will be removed in a future version. Please use `MediaCapture` instead, which provides both audio and video capture capabilities with improved performance.

```javascript
// ❌ Deprecated approach
import { AudioCapture } from "@voibo/desktop-audio-capture";
const audioCapture = new AudioCapture();

// ✅ Recommended approach
import { MediaCapture } from "@voibo/desktop-audio-capture";
const mediaCapture = new MediaCapture();
```

## License

MIT
