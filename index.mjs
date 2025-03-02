import path from "path";
import { fileURLToPath } from "url";
import bindings from "bindings";
import { EventEmitter } from "events";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// addon.node から AudioCapture と MediaCapture を取得
const { AudioCapture, MediaCapture } = bindings("addon");

// EventEmitter を継承させる
Object.setPrototypeOf(AudioCapture.prototype, EventEmitter.prototype);
Object.setPrototypeOf(MediaCapture.prototype, EventEmitter.prototype);

// MediaCaptureQualityの定義
export const MediaCaptureQuality = {
  High: 0,
  Medium: 1,
  Low: 2,
};

// クラスをエクスポート
export { AudioCapture, MediaCapture };
