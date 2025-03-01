const { EventEmitter } = require("events");
const bindings = require("bindings");

const addon = bindings("addon");

// プロトタイプを正しく設定
Object.setPrototypeOf(addon.ScreenCapture.prototype, EventEmitter.prototype);
Object.setPrototypeOf(addon.AudioCapture.prototype, EventEmitter.prototype);

module.exports = addon;
