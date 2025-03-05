import { EventEmitter } from "events";
import path from "path";
import { fileURLToPath } from "url";
import bindings from "bindings";
import process from "process";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Export quality setting constants
export const MediaCaptureQuality = {
  High: 0,
  Medium: 1,
  Low: 2,
};

/// AudioCapture
// AudioCapture is working as is, so do not modify
const { AudioCapture } = bindings("addon");
Object.setPrototypeOf(AudioCapture.prototype, EventEmitter.prototype);
export { AudioCapture };

/// MediaCapture
// Currently only available on Apple Silicon environment
const isAppleSilicon =
  process.platform === "darwin" && process.arch === "arm64";
let MediaCaptureImplementation;
if (isAppleSilicon) {
  // Only use the actual MediaCapture implementation on Apple Silicon
  const { MediaCapture } = bindings("addon");

  class EnhancedMediaCapture extends EventEmitter {
    constructor() {
      super();
      this._nativeInstance = new MediaCapture();

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
      return MediaCapture.enumerateMediaCaptureTargets(...args);
    }
  }

  MediaCaptureImplementation = EnhancedMediaCapture;
} else {
  // For unsupported environments, provide a dummy MediaCapture class
  class UnsupportedMediaCapture extends EventEmitter {
    constructor() {
      super();
      console.warn(
        "MediaCapture is only available on Apple Silicon (ARM64) macOS devices."
      );
    }

    startCapture() {
      throw new Error(
        "MediaCapture is not supported on this platform. Only available on Apple Silicon macOS."
      );
    }

    stopCapture() {
      throw new Error(
        "MediaCapture is not supported on this platform. Only available on Apple Silicon macOS."
      );
    }

    static enumerateMediaCaptureTargets() {
      throw new Error(
        "MediaCapture is not supported on this platform. Only available on Apple Silicon macOS."
      );
    }
  }

  MediaCaptureImplementation = UnsupportedMediaCapture;
}

export { MediaCaptureImplementation as MediaCapture };
