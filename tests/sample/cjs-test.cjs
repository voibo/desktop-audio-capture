// CommonJS test file
const { AudioCapture, MediaCapture } = require('@voibo/desktop-audio-capture');

console.log("CommonJS import test");
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

console.log("\nTest complete - CommonJS import works!");