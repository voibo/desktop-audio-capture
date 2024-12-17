import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import bindings from 'bindings';
import { EventEmitter } from 'events';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const AudioCapture = bindings({
  bindings: 'addon',
  try: [
    ['module_root', 'build', 'Debug', 'bindings'],
    ['module_root', 'build', 'Release', 'bindings'],
    ['module_root', 'bin', 'platform', 'arch', 'bindings'],
  ],
}).AudioCapture;

Object.setPrototypeOf(AudioCapture.prototype, EventEmitter.prototype);

export { AudioCapture };
