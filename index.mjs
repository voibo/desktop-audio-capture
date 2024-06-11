//import fs from 'fs';
import bindings from 'bindings';
import { EventEmitter } from 'events';

const AudioCapture = bindings('addon').AudioCapture;
Object.setPrototypeOf(AudioCapture.prototype, EventEmitter.prototype);

export { AudioCapture };

/*
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
    ws.write(data);
  });

  capture.startCapture({
    channels: 2,
    sampleRate: 48000,
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

//showDesktopWindows();
captureDesktopAudio();
*/
