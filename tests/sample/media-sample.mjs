import {
  MediaCapture,
  MediaCaptureQuality,
} from "@voibo/desktop-audio-capture";
import fs from "fs";
import * as fsPromises from "fs/promises";
import path from "path";

console.log("Desktop Audio Capture Sample - MediaCapture");

// Check if the platform is supported
const isSupportedPlatform =
  (process.platform === "darwin" && process.arch === "arm64") ||
  process.platform === "win32";

if (!isSupportedPlatform) {
  console.warn(
    "MediaCapture is only available on Apple Silicon (ARM64) macOS devices and Windows."
  );
  process.exit(1);
}

async function recordCapture(durationMs = 5000) {
  console.log("=== Media Capture Recording Test ===");

  // Create timestamp-based folder name
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const captureDir = path.join(process.cwd(), `output/capture_${timestamp}`);
  const imagesDir = path.join(captureDir, "images");
  const audioDir = path.join(captureDir, "audio");

  // Frame counter
  let frameCount = 0;

  // Audio buffer (to collect Float32Array data)
  const audioSampleRate = 16000;
  const audioChannels = 1;

  const audioChunks = [];
  let audioFormat = {
    sampleRate: audioSampleRate,
    channels: audioChannels,
    bytesPerSample: 4, // f32le format
  };

  // Create folders
  await fsPromises.mkdir(captureDir, { recursive: true });
  await fsPromises.mkdir(imagesDir, { recursive: true });
  await fsPromises.mkdir(audioDir, { recursive: true });

  console.log(`Created capture directory: ${captureDir}`);

  let capture = null;

  try {
    // Clear capture object
    if (capture) {
      capture.removeAllListeners();
    }

    // Create new capture
    capture = new MediaCapture();

    // Add error handler first
    capture.on("error", (err) => {
      console.error("Capture error:", err.message);
    });

    // Frame and audio data counters
    let frameCount = 0;
    let audioSampleCount = 0;

    // Video frame processing
    capture.on("video-frame", (frame) => {
      console.log(`Video frame: ${frame.width}x${frame.height}`);
      try {
        try {
          const frameFile = path.join(
            imagesDir,
            `${frame.timestamp}.jpg`
          );

          // Synchronous method - using Node.js standard fs module
          fs.writeFileSync(frameFile, Buffer.from(frame.data));
          frameCount++; // Only increment counter on success
        } catch (err) {
          console.error(`Frame save error: ${err.message}`);
        }
      } catch (err) {
        console.error("Frame processing error:", err);
      }
    });

    // Audio data processing
    capture.on("audio-data", (audioData, sampleRate, channels) => {
      try {
        audioSampleCount += audioData.length;
        if (audioSampleCount % 10000 === 0) {
          console.log(
            `Audio data: ${audioData.length} samples, ${channels} channels, ${sampleRate}Hz`
          );
        }

        // Save buffer as is
        if (audioData && audioData.buffer) {
          audioChunks.push(Buffer.from(audioData.buffer));
        }
      } catch (err) {
        console.error("Audio processing error:", err);
      }
    });

    // Enumerate available targets
    const targets = await MediaCapture.enumerateMediaCaptureTargets();
    console.log("Available capture targets:");
    targets.forEach((target, index) => {
      console.log(
        `[${index}] ${target.title || "Untitled"} (${
          target.isDisplay ? "Display" : "Window"
        })`
      );
      console.log(
        `    displayId: ${target.displayId}, windowId: ${target.windowId}`
      );
    });

    if (targets.length === 0) {
      console.error("No available capture targets");
      return;
    }

    // Get target ID - select first display
    const displayTarget = targets.find((t) => t.isDisplay) || targets[0];

    // Capture settings - fix: use displayId instead of targetId
    const config = {
      displayId: displayTarget.displayId, // use displayId instead of targetId
      frameRate: 1,
      quality: MediaCaptureQuality.High,
      audioSampleRate: audioSampleRate,
      audioChannels: audioChannels,
    };

    console.log(`Starting capture for ${durationMs / 1000} seconds...`);
    console.log(
      `Selected target: ${displayTarget.title || "Untitled"} (displayId: ${
        displayTarget.displayId
      })`
    );

    // Start capture
    try {
      capture.startCapture(config);
    } catch (err) {
      console.error("Capture start error:", err);
      throw err;
    }

    // Capture for specified time
    await new Promise((resolve) => setTimeout(resolve, durationMs));

    console.log("Stopping capture...");
    try {
      await capture.stopCapture();
    } catch (err) {
      console.error("Capture stop error:", err);
    }

    // Save audio data to a single file
    if (audioChunks.length > 0) {
      const audioFile = path.join(audioDir, "audio.f32le");
      const audioData = Buffer.concat(audioChunks);
      await fsPromises.writeFile(audioFile, audioData);

      // Add frame count to format information
      audioFormat.totalSamples = audioData.length / audioFormat.bytesPerSample;
      audioFormat.totalFrames = audioFormat.totalSamples / audioFormat.channels;

      // Save audio format information as JSON file
      await fsPromises.writeFile(
        path.join(audioDir, "audio-info.json"),
        JSON.stringify(audioFormat, null, 2)
      );

      console.log(
        `Audio saved: ${audioFormat.totalFrames} frames, total samples: ${audioFormat.totalSamples}`
      );
    }

    console.log(`Recording complete - Frame count: ${frameCount}`);
    console.log(`Save location: ${captureDir}`);
    console.log(
      `Audio playback command: ffplay -f f32le -ar ${
        audioFormat.sampleRate
      } -ch_layout ${audioChannels == 1 ? "mono" : "stereo"} "${path.join(
        audioDir,
        "audio.f32le"
      )}"`
    );
  } catch (err) {
    console.error("Test error:", err);
  } finally {
    // Enhanced capture cleanup
    if (capture) {
      try {
        console.log("Cleaning up resources...");

        // Remove listeners
        try {
          capture.removeAllListeners();
          console.log("Removed event listeners");
        } catch (e) {
          console.error("Listener removal error:", e);
        }

        // Stop processing
        try {
          if (capture.stopCapture) {
            console.log("Starting capture stop process...");
            capture.stopCapture();
            console.log("Capture stop process complete");
          }
        } catch (e) {
          console.error("Stop process error (ignored):", e.message);
        }

        // Explicit garbage collection
        console.log("Releasing objects...");
        capture = null;
      } catch (err) {
        console.error("Cleanup error:", err);
      }
    }
  }
}

async function run() {
  try {
    await recordCapture(10000);
    console.log("Recording process complete");
  } catch (err) {
    console.error("Unexpected error:", err);
  } finally {
    // Wait to release resources
    setTimeout(() => {
      console.log("Process terminating");
      process.exit(0);
    }, 2000);
  }
}

run();
