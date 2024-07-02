import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import bindings from 'bindings';
import { EventEmitter } from 'events';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
let AudioCapture;
let moduleRoot = '';
if (process.platform === 'darwin') {
  moduleRoot = 'bin/darwin';
} else if (process.platform === 'win32') {
  moduleRoot = 'bin/win32';
}
AudioCapture = bindings({
  bindings: 'addon',
  module_root: path.join(__dirname, moduleRoot)
}).AudioCapture;

Object.setPrototypeOf(AudioCapture.prototype, EventEmitter.prototype);

export { AudioCapture };


async function showDesktopWindows() {
  const [displays, windows] = await AudioCapture.enumerateDesktopWindows();
  console.log("displays:");
  displays.forEach(i => console.log(`[${i.displayId}]`));
  console.log("windows:");
  windows.forEach(i => console.log(`[${i.windowId}] ${i.title}`));
}

function captureDesktopAudio() {
  const ws = fs.createWriteStream('test.raw');

  const capture = new AudioCapture();

  capture.on('error', (error) => {
    console.error(error);
  });
  capture.on('data', (data) => {
    ws.write(Buffer.from(data.buffer));
  });

  capture.startCapture({
    channels: 1,
    sampleRate: 16000,
    displayId: 1,
  });

  let closed = false;
  process.once('SIGINT', async () => {
    if (closed) {
      return;
    }
    await capture.stopCapture();
    ws.close();
    console.debug("exit");
    closed = true;
  });
}

console.log('start');
showDesktopWindows();
captureDesktopAudio();
console.log('end');
