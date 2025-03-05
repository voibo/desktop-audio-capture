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

    // メソッドをこのクラスにバインド
    this.startCapture = this._nativeInstance.startCapture.bind(
      this._nativeInstance
    );
    this.stopCapture = this._nativeInstance.stopCapture.bind(
      this._nativeInstance
    );

    // より堅牢なイベント転送の仕組み
    const self = this;
    this._nativeInstance.emit = function (event, ...args) {
      // thisではなくselfにイベントを転送
      return self.emit(event, ...args);
    };

    // emit関数の参照をC++側で正しく取得できるようにする
    Object.defineProperty(this._nativeInstance, "_events", {
      value: {},
      writable: true,
      enumerable: false,
    });
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
