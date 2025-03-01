import { EventEmitter } from "events";

// 共通インターフェース
export interface DisplayInfo {
  displayId: number;
}

export interface WindowInfo {
  windowId: number;
  title: string;
}

// オーディオキャプチャ関連
export interface StartCaptureConfig {
  channels: number;
  sampleRate: number;
  displayId?: number;
  windowId?: number;
}

interface AudioCaptureOptions {
  sampleRate?: number;
  channels?: number;
}

// スクリーンキャプチャ関連
export interface ScreenCaptureOptions {
  frameRate?: number; // フレームレート (デフォルト: 10)
  quality?: number; // 品質 (0: 高, 1: 中, 2: 低)
  displayId?: number; // キャプチャ対象ディスプレイID
  windowId?: number; // キャプチャ対象ウィンドウID
  bundleId?: string; // キャプチャ対象アプリケーションのバンドルID
}

// フレームメタデータ
export interface FrameMetadata {
  width: number; // フレーム幅（ピクセル）
  height: number; // フレーム高さ（ピクセル）
  timestamp: number; // キャプチャ時間（秒）
}

// クラス定義
export class AudioCapture extends EventEmitter {
  constructor(options?: AudioCaptureOptions);
  static enumerateDesktopWindows(): Promise<[DisplayInfo[], WindowInfo[]]>;
  startCapture(config: StartCaptureConfig): void;
  stopCapture(): Promise<void>;
  isCapturing(): boolean;

  // イベント
  on(event: "data", listener: (data: Buffer) => void): this;
  on(event: "error", listener: (error: Error) => void): this;
}

export class ScreenCapture extends EventEmitter {
  constructor(options?: ScreenCaptureOptions);
  startCapture(options?: ScreenCaptureOptions): void;
  stopCapture(): Promise<void>;
  isCapturing(): boolean;

  // イベント
  on(
    event: "frame",
    listener: (imageData: Buffer, metadata: FrameMetadata) => void
  ): this;
  on(event: "error", listener: (error: Error) => void): this;
}
