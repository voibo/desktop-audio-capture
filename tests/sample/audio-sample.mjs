import { AudioCapture } from "@voibo/desktop-audio-capture";
import fs from "fs/promises";
import path from "path";

console.log("Desktop Audio Capture Sample - AudioCapture");

// Add debug information to audio-sample.mjs
console.log("System information:", {
  nodeVersion: process.version,
  platform: process.platform,
  arch: process.arch,
  pid: process.pid,
  execPath: process.execPath,
});

async function captureAudioToPCM() {
  // Adjust channel settings based on platform
  const isWindows = process.platform === "win32";

  // Adjust audio settings
  const audioConfig = {
    sampleRate: 44100, // Changed from 48000 to 44100
    channels: isWindows ? 1 : 2, // 1 channel for Windows, 2 channels for macOS
  };

  console.log(
    `Platform: ${process.platform}, Number of channels: ${audioConfig.channels}`
  );

  // Array for accumulating audio data
  let audioBuffer = [];
  let captureStartTime = null;
  let captureEndTime = null;

  try {
    // Create audio capture instance
    const audioCapture = new AudioCapture();

    // Enumerate available displays and windows
    console.log("Retrieving screen information...");
    const [displays, windows] = await AudioCapture.enumerateDesktopWindows();
    console.log(`Displays: ${displays.length}, Windows: ${windows.length}`);

    if (displays.length === 0) {
      console.error("No displays available for capture");
      return;
    }

    // Set up event listeners
    audioCapture.on("data", (buffer) => {
      // Create Float32Array from buffer
      const float32Array = new Float32Array(buffer);

      // Add directly to array
      audioBuffer.push(...float32Array);

      if (captureStartTime === null) {
        captureStartTime = Date.now();
        console.log("Received first audio data");
      }

      // Display progress (every 100ms)
      if (audioBuffer.length % 4800 === 0) {
        // Equivalent to 100ms (48000Hz × 0.1 seconds = 4800 samples)
        const elapsedSeconds = (Date.now() - captureStartTime) / 1000;
        const bufferSizeKb = (audioBuffer.length * 4) / 1024;
        console.log(
          `Recording: ${elapsedSeconds.toFixed(
            1
          )} seconds / 5 seconds (${bufferSizeKb.toFixed(0)}KB) Sample count: ${
            audioBuffer.length
          }`
        );

        // Sample range check (data validation)
        const lastChunk = float32Array.slice(
          0,
          Math.min(10, float32Array.length)
        );
        const hasSoundData = lastChunk.some((v) => Math.abs(v) > 0.01);
        if (hasSoundData) {
          console.log(
            "Sound data detected: ",
            Array.from(lastChunk.slice(0, 3)).map((v) => v.toFixed(4))
          );
        }
      }
    });

    audioCapture.on("error", (err) => {
      console.error("Capture error:", err);
    });

    // Select main display
    const displayTarget = displays[0];
    console.log(
      `Starting capture of main display (ID: ${displayTarget.displayId})`
    );

    // Capture configuration
    const config = {
      displayId: displayTarget.displayId,
      windowId: 0,
      channels: audioConfig.channels,
      sampleRate: audioConfig.sampleRate,
    };

    // Start capture
    console.log("Starting capture...");
    await audioCapture.startCapture(config);
    console.log("Capture started successfully");

    // Wait for 5 seconds
    const captureTime = 5000; // 5 seconds
    console.log(`Recording for ${captureTime / 1000} seconds...`);
    await new Promise((resolve) => setTimeout(resolve, captureTime));

    // Stop capture
    console.log("Stopping capture...");
    await audioCapture.stopCapture();
    captureEndTime = Date.now();
    console.log("Capture stopped successfully");

    // Process results
    if (audioBuffer.length > 0) {
      const duration = (captureEndTime - captureStartTime) / 1000;
      console.log(`Recording complete: Sample count: ${audioBuffer.length}`);

      // Convert to Float32Array
      const finalFloat32Array = new Float32Array(audioBuffer);

      // Convert to Buffer
      const finalBuffer = Buffer.from(finalFloat32Array.buffer);

      // Create filename
      const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
      const outputDir = path.join(process.cwd(), "output");
      await fs.mkdir(outputDir, { recursive: true });

      // PCM file path
      const pcmFilePath = path.join(
        outputDir,
        `audio-capture-${timestamp}.f32le`
      );

      // Save PCM file
      await fs.writeFile(pcmFilePath, finalBuffer);
      console.log(`PCM file saved: ${pcmFilePath}`);

      // Save metadata
      const metadataFilePath = path.join(
        outputDir,
        `audio-capture-${timestamp}.json`
      );

      const expectedDuration =
        audioBuffer.length / (audioConfig.sampleRate * audioConfig.channels);

      const metadata = {
        format: "PCM",
        sampleRate: audioConfig.sampleRate,
        channels: audioConfig.channels,
        bitDepth: 32,
        encoding: "float",
        endianness: "little",
        recordDuration: duration,
        expectedPlayDuration: expectedDuration,
        totalSamples: audioBuffer.length,
        fileSize: finalBuffer.length,
      };

      // Save metadata file
      await fs.writeFile(metadataFilePath, JSON.stringify(metadata, null, 2));

      console.log(`=== Capture Complete ===`);
      console.log(`Float32 PCM file: ${pcmFilePath}`);
      console.log(`Metadata: ${metadataFilePath}`);
      console.log(
        `File size: ${(finalBuffer.length / 1024 / 1024).toFixed(2)} MB`
      );
      console.log(`Recording time: ${duration.toFixed(2)} seconds`);
      console.log(
        `Expected playback time: ${expectedDuration.toFixed(2)} seconds`
      );
      console.log(`Total sample count: ${audioBuffer.length}`);
      console.log(`Number of channels: ${audioConfig.channels}`);
      console.log(`Sample rate: ${audioConfig.sampleRate} Hz`);
      console.log(`\nPlayback command:`);
      console.log(
        `ffplay -f f32le -ar ${audioConfig.sampleRate} -ch_layout ${
          audioConfig.channels == 1 ? "mono" : "stereo"
        } "${pcmFilePath}"`
      );
    } else {
      console.log("No audio data was received. Please check the following:");
      console.log("- System audio is playing");
      console.log("- Screen capture permissions are granted");
      console.log("- Main display is correctly selected");
    }

    // Cleanup
    audioCapture.removeAllListeners();
  } catch (err) {
    console.error("Test error:", err);
  }
}

// Run main process
captureAudioToPCM().catch((err) => {
  console.error("Unhandled error:", err);
  process.exit(1);
});

// Cleanup handling
process.on("SIGINT", () => {
  console.log("Interrupted. Cleaning up...");
  process.exit(0);
});
