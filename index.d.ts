import { EventEmitter } from 'events';

export interface DisplayInfo {
  displayId: number;
}

export interface WindowInfo {
  windowId: number;
  title: string;
}

export interface StartCaptureConfig {
  channels: number;
  sampleRate: number;
  displayId?: number;
  windowId?: number;
}

export interface AudioCapture extends EventEmitter {
  startCapture(config: StartCaptureConfig): void;
  stopCapture(): Promise<void>;
}
export var AudioCapture: AudioCaptureConstructor;

interface AudioCaptureConstructor {
  new(): AudioCapture;
  enumerateDesktopWindows(): Promise<[DisplayInfo[], WindowInfo[]]>;
}
