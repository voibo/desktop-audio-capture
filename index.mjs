import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import bindings from 'bindings';
import { EventEmitter } from 'events';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const AudioCapture = bindings('addon').AudioCapture;

Object.setPrototypeOf(AudioCapture.prototype, EventEmitter.prototype);

export { AudioCapture };
