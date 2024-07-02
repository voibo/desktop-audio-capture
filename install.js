import { exec } from 'child_process';
import fs from 'fs';

console.log(`running npm install for platform: ${process.platform}`);
if (process.platform === 'darwin') {
  exec('npx cmake-js compile', (error) => {
    if (error) {
      console.error(`Error in npm install: ${error}`);
      return;
    }

    // TODO: MAC
    // copy mac addon.node into ./bin/darwin/Release, and add addon.node to git.

    console.error(`TODO: darwin addon.node must be copied into ./bin/darwin/Release/ folder`);
    //console.log('module installed successfully.');
  });
} else if (process.platform === 'win32') {
  exec('npx cmake-js compile --O build/win32 --runtime=electron --runtime-version=30.1.0 --arch=x64', (error) => {
    if (error) {
      console.error(`Error in npm install: ${error}`);
      return;
    }
    fs.mkdirSync('./bin/win32/Release', { recursive: true });
    fs.copyFileSync('./build/win32/Release/addon.node', './bin/win32/Release/addon.node');
    console.log('module installed successfully.');
  });
} else {
  console.log(`unknown platform ${process.platform}`);
}
