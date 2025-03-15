// ESM test file
import { AudioCapture, MediaCapture, MediaCaptureQuality, isMediaCaptureSupported } from '@voibo/desktop-audio-capture';

console.log("ESM import test");
console.log("System information:", {
  nodeVersion: process.version,
  platform: process.platform,
  arch: process.arch,
});

// Test AudioCapture (deprecated but should work)
console.log("\nAudioCapture available:", typeof AudioCapture === 'function');

// Test MediaCapture
console.log("\nMediaCapture available:", typeof MediaCapture === 'function');

// Check implementation details
if (typeof MediaCapture === 'function') {
  console.log("MediaCapture.isSupported():", MediaCapture.isSupported());
}

// Check utils
console.log("\nisMediaCaptureSupported():", isMediaCaptureSupported());

// Check constants
console.log("\nMediaCaptureQuality.High:", MediaCaptureQuality.High);

console.log("\nTest complete - ESM import works!");