import { EventEmitter } from "events";

// Common type definitions
export interface DisplayInfo {
  displayId: number;
}

export interface WindowInfo {
  windowId: number;
  title: string;
}

// AudioCapture related type definitions
export interface StartCaptureConfig {
  channels: number;
  sampleRate: number;
  displayId?: number;
  windowId?: number;
}

/**
 * @deprecated AudioCapture is deprecated and will be removed in a future version.
 * Please use MediaCapture instead, which provides both audio and video capture capabilities.
 */
export interface AudioCapture extends EventEmitter {
  startCapture(config: StartCaptureConfig): void;
  stopCapture(): Promise<void>;

  // AudioCapture events
  on(event: "data", listener: (buffer: Buffer) => void): this;
  on(event: "error", listener: (error: Error) => void): this;
  once(event: "data", listener: (buffer: Buffer) => void): this;
  once(event: "error", listener: (error: Error) => void): this;
}

/**
 * @deprecated AudioCapture is deprecated and will be removed in a future version.
 * Please use MediaCapture instead, which provides both audio and video capture capabilities.
 */
export var AudioCapture: AudioCaptureConstructor;

/**
 * @deprecated AudioCapture is deprecated and will be removed in a future version.
 * Please use MediaCapture instead, which provides both audio and video capture capabilities.
 */
interface AudioCaptureConstructor {
  new (): AudioCapture;
  /**
   * @deprecated Use MediaCapture.enumerateMediaCaptureTargets instead.
   */
  enumerateDesktopWindows(): Promise<[DisplayInfo[], WindowInfo[]]>;
}

// MediaCapture related type definitions
export interface MediaCaptureTarget {
  isDisplay: boolean;
  isWindow: boolean;
  displayId: number;
  windowId: number;
  width: number;
  height: number;
  title?: string;
  appName?: string;
  frame: {
    width: number;
    height: number;
  };
}

// Export constants matching the implementation
export enum MediaCaptureQuality {
  High,
  Medium,
  Low,
}

export interface MediaCaptureConfig {
  frameRate: number;
  quality: number; // Using MediaCaptureQuality enum values (High, Medium, Low)
                   // Both platforms: quality High=90%, Medium=75%, Low=50%
  qualityValue?: number; // Precise JPEG quality value (0-100), overrides quality enum if specified
                        // Works on both Windows and macOS
  audioSampleRate: number;
  audioChannels: number;
  displayId?: number;
  windowId?: number;
  bundleId?: string;
  isElectron?: boolean; // isElectron is used to determine if the capture is for electron app
}

export interface MediaCaptureVideoFrame {
  data: Uint8Array;
  width: number;
  height: number;
  bytesPerRow: number;
  timestamp: number;
  isJpeg: boolean; // true for JPEG encoded frames (always true on Windows), false for RAW format (macOS only)
}

export interface MediaCapture extends EventEmitter {
  startCapture(config: MediaCaptureConfig): void;
  stopCapture(): Promise<void>;

  on(
    event: "video-frame",
    listener: (frame: MediaCaptureVideoFrame) => void
  ): this;

  on(
    event: "audio-data",
    listener: (
      audioData: Float32Array,
      sampleRate: number,
      channels: number
    ) => void
  ): this;

  on(event: "error", listener: (error: Error) => void): this;
  on(event: "exit", listener: () => void): this;

  once(
    event: "video-frame",
    listener: (frame: MediaCaptureVideoFrame) => void
  ): this;

  once(
    event: "audio-data",
    listener: (
      audioData: Float32Array,
      sampleRate: number,
      channels: number
    ) => void
  ): this;

  once(event: "error", listener: (error: Error) => void): this;
  once(event: "exit", listener: () => void): this;
}

export var MediaCapture: MediaCaptureConstructor;

interface MediaCaptureConstructor {
  new (): MediaCapture;
  enumerateMediaCaptureTargets(
    type?: MediaCaptureTargetType
  ): Promise<MediaCaptureTarget[]>;

  /**
   * Check if MediaCapture is supported on the current platform
   * @returns True if the current environment supports MediaCapture
   */
  isSupported(): boolean;
}

export enum MediaCaptureTargetType {
  All,
  Screen,
  Window,
}

/**
 * Check if MediaCapture is supported on the current platform
 * @returns True if the current environment supports MediaCapture
 */
export function isMediaCaptureSupported(): boolean;
