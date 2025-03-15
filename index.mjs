import { EventEmitter } from "events";
import path from "path";
import { fileURLToPath } from "url";
import bindings from "bindings";
import process from "process";
import { createRequire } from "module";

const require = createRequire(import.meta.url);
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export const MediaCaptureQuality = {
  High: 0,
  Medium: 1,
  Low: 2,
};

export const MediaCaptureTargetType = {
  All: 0,
  Screen: 1,
  Window: 2,
};

/// AudioCapture
// DEPRECATED: AudioCapture is deprecated and will be removed in a future version.
// Use MediaCapture instead for both audio and video capture capabilities.
const { AudioCapture: _AudioCapture } = bindings("addon");
Object.setPrototypeOf(_AudioCapture.prototype, EventEmitter.prototype);

// Create a proxy to emit deprecation warning when AudioCapture is used
class AudioCapture extends _AudioCapture {
  constructor() {
    console.warn(
      "DEPRECATED: AudioCapture is deprecated and will be removed in a future version. " +
        "Please use MediaCapture instead, which provides both audio and video capture capabilities."
    );
    super();
  }

  // Forward static methods
  static enumerateDesktopWindows(...args) {
    console.warn(
      "DEPRECATED: AudioCapture.enumerateDesktopWindows is deprecated. " +
        "Please use MediaCapture.enumerateMediaCaptureTargets instead."
    );
    return _AudioCapture.enumerateDesktopWindows(...args);
  }
}

export { AudioCapture };

/// MediaCapture
// Available on Apple Silicon macOS and Windows
const isSupportedPlatform =
  (process.platform === "darwin" && process.arch === "arm64") ||
  process.platform === "win32";
let MediaCaptureImplementation;
if (isSupportedPlatform) {
  // Use the actual MediaCapture implementation on supported platforms
  const { MediaCapture: NativeMediaCapture } = bindings("addon");

  class EnhancedMediaCapture extends EventEmitter {
    constructor() {
      super();
      this._nativeInstance = new NativeMediaCapture();

      // Bind methods to this class
      this.startCapture = this._nativeInstance.startCapture.bind(
        this._nativeInstance
      );
      this.stopCapture = this._nativeInstance.stopCapture.bind(
        this._nativeInstance
      );

      // More robust event forwarding mechanism
      const self = this;
      this._nativeInstance.emit = function (event, ...args) {
        // Forward events to self instead of this
        return self.emit(event, ...args);
      };

      // Allow C++ side to correctly get reference to emit function
      Object.defineProperty(this._nativeInstance, "_events", {
        value: {},
        writable: true,
        enumerable: false,
      });
    }

    // Add static methods as needed
    static enumerateMediaCaptureTargets(...args) {
      return NativeMediaCapture.enumerateMediaCaptureTargets(...args);
    }

    /**
     * Check if MediaCapture is supported on the current platform
     * @returns {boolean} True if the current environment supports MediaCapture
     */
    static isSupported() {
      return true;
    }
  }

  MediaCaptureImplementation = EnhancedMediaCapture;
} else {
  // For unsupported environments, provide a dummy MediaCapture class
  class UnsupportedMediaCapture extends EventEmitter {
    constructor() {
      super();
      console.warn(
        "MediaCapture is only available on Apple Silicon (ARM64) macOS devices and Windows."
      );
    }

    startCapture() {
      throw new Error(
        "MediaCapture is not supported on this platform. Only available on Apple Silicon macOS and Windows."
      );
    }

    stopCapture() {
      throw new Error(
        "MediaCapture is not supported on this platform. Only available on Apple Silicon macOS and Windows."
      );
    }

    static enumerateMediaCaptureTargets() {
      throw new Error(
        "MediaCapture is not supported on this platform. Only available on Apple Silicon macOS and Windows."
      );
    }

    /**
     * Check if MediaCapture is supported on the current platform
     * @returns {boolean} True if the current environment supports MediaCapture
     */
    static isSupported() {
      return false;
    }
  }

  MediaCaptureImplementation = UnsupportedMediaCapture;
}

// Export a standalone function for checking support without instantiation
export function isMediaCaptureSupported() {
  return isSupportedPlatform;
}

export { MediaCaptureImplementation as MediaCapture };
