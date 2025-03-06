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

export interface AudioCapture extends EventEmitter {
  startCapture(config: StartCaptureConfig): void;
  stopCapture(): Promise<void>;

  // AudioCapture events
  on(event: "data", listener: (buffer: Buffer) => void): this;
  on(event: "error", listener: (error: Error) => void): this;
  once(event: "data", listener: (buffer: Buffer) => void): this;
  once(event: "error", listener: (error: Error) => void): this;
}

export var AudioCapture: AudioCaptureConstructor;

interface AudioCaptureConstructor {
  new (): AudioCapture;
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
  quality: number; // Using MediaCaptureQuality constant values
  audioSampleRate: number;
  audioChannels: number;
  displayId?: number;
  windowId?: number;
  bundleId?: string;
}

export interface MediaCaptureVideoFrame {
  data: Uint8Array;
  width: number;
  height: number;
  bytesPerRow: number;
  timestamp: number;
  isJpeg: boolean;
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
  enumerateMediaCaptureTargets(type?: number): Promise<MediaCaptureTarget[]>;
}

export enum MediaCaptureTargetType {
  All,
  Screen,
  Window,
}
