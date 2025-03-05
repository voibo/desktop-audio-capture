import { EventEmitter } from "events";
import path from "path";
import { fileURLToPath } from "url";
import bindings from "bindings";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// addon.node から AudioCapture と MediaCapture を取得
const { AudioCapture, MediaCapture } = bindings("addon");

// AudioCapture　はこれで動作しているので修正してはいけない
Object.setPrototypeOf(AudioCapture.prototype, EventEmitter.prototype);
export { AudioCapture };

// EventEmitterの初期化方法を改善
class EnhancedMediaCapture extends EventEmitter {
  constructor() {
    super();
    this._nativeInstance = new MediaCapture();
    // ネイティブインスタンスのメソッドをこのクラスにバインド
    this.startCapture = this._nativeInstance.startCapture.bind(
      this._nativeInstance
    );
    this.stopCapture = this._nativeInstance.stopCapture.bind(
      this._nativeInstance
    );

    // ネイティブイベントをこのEventEmitterに転送
    this._nativeInstance.on = (event, listener) => {
      this.on(event, listener);
      return this;
    };

    this._nativeInstance.emit = (event, ...args) => {
      return this.emit(event, ...args);
    };
  }

  // 必要に応じて静的メソッドを追加
  static enumerateMediaCaptureTargets(...args) {
    return MediaCapture.enumerateMediaCaptureTargets(...args);
  }
}
export { EnhancedMediaCapture as MediaCapture };

// エクスポートする品質設定の定数
export const MediaCaptureQuality = {
  High: 0,
  Medium: 1,
  Low: 2,
};
