import { MediaCapture } from "../../index.mjs";
import fs from "fs";
import * as fsPromises from "fs/promises";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

if (typeof process.getActiveResourcesInfo === "function") {
  setInterval(() => {
    console.log("Active Resources:", process.getActiveResourcesInfo());
  }, 1000);
}

async function recordCapture(durationMs = 5000) {
  console.log("=== Media Capture Recording Test ===");

  // Create a timestamp-based folder name
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const captureDir = path.join(__dirname, `../../output/capture_${timestamp}`);
  const imagesDir = path.join(captureDir, "images");
  const audioDir = path.join(captureDir, "audio");

  // Frame counter
  let frameCount = 0;

  // Audio buffer (collect Float32Array data)
  const audioChunks = [];
  let audioFormat = {
    sampleRate: 48000,
    channels: 2,
    bytesPerSample: 4, // f32le format
  };

  // Create folders
  await fsPromises.mkdir(captureDir, { recursive: true });
  await fsPromises.mkdir(imagesDir, { recursive: true });
  await fsPromises.mkdir(audioDir, { recursive: true });

  console.log(`Created capture directory: ${captureDir}`);

  let capture = null;

  try {
    // Clear the capture object
    if (capture) {
      capture.removeAllListeners();
    }

    // Create a new capture
    capture = new MediaCapture();

    // Add error handler first
    capture.on("error", (err) => {
      console.error("Capture Error:", err.message);
    });

    // Frame and audio data counters
    let frameCount = 0;
    let audioSampleCount = 0;

    // Video frame processing - Add error handling
    capture.on("video-frame", (frame) => {
      try {
        // Output basic information only (reduce processing load)
        if (frameCount % 5 === 0) {
          console.log(
            `Frame ${frameCount}: ${frame.width}x${frame.height}, ${
              frame.isJpeg ? "JPEG" : "RAW"
            } Data`
          );
        }

        // Validation
        if (!frame || !frame.data) {
          console.error(`Invalid Frame: ${frame ? "No Data" : "No Frame"}`);
          return;
        }

        try {
          const frameFile = path.join(
            imagesDir,
            `frame_${String(frameCount).padStart(5, "0")}.jpg`
          );

          // Synchronous method - Use Node.js standard fs module
          fs.writeFileSync(frameFile, Buffer.from(frame.data));
          frameCount++; // Increment count only if successful
        } catch (err) {
          console.error(`Error Saving Frame: ${err.message}`);
        }
      } catch (err) {
        console.error("Frame Processing Error:", err);
      }
    });

    // Audio data processing - Add error handling
    capture.on("audio-data", (audioData, sampleRate, channels) => {
      try {
        audioSampleCount += audioData.length;
        if (audioSampleCount % 10000 === 0) {
          console.log(
            `Audio Data: ${audioData.length} Samples, ${channels} Channels, ${sampleRate}Hz`
          );
        }

        // Minimal processing
        console.log(
          `Audio Buffer Received: ${channels} Channels, ${
            audioData.length / channels
          } Frames`
        );

        // Save the buffer as is (minimize conversion processing)
        if (audioData && audioData.buffer) {
          audioChunks.push(Buffer.from(audioData.buffer));
        }
      } catch (err) {
        console.error("Audio Processing Error:", err);
      }
    });

    // Error handling
    capture.on("error", (err) => console.error("Capture Error:", err));

    // Capture settings
    const config = {
      frameRate: 1,
      quality: 0, // High quality
      audioSampleRate: 48000,
      audioChannels: 2,
      displayId: 1, // Main display ID
    };

    console.log(`Starting Capture for ${durationMs / 1000} Seconds...`);

    // Since the new interface might not be a Promise, add error handling
    try {
      capture.startCapture(config);
    } catch (err) {
      console.error("Capture Start Error:", err);
      throw err;
    }

    // Capture for the specified duration
    await new Promise((resolve) => setTimeout(resolve, durationMs));

    console.log("Stopping Capture...");
    try {
      await capture.stopCapture();
    } catch (err) {
      console.error("Capture Stop Error:", err);
    }

    // Save audio data to a single file
    if (audioChunks.length > 0) {
      const audioFile = path.join(audioDir, "audio.f32le");
      const audioData = Buffer.concat(audioChunks);
      await fsPromises.writeFile(audioFile, audioData);

      // Add frame count to format information
      audioFormat.totalSamples = audioData.length / audioFormat.bytesPerSample;
      audioFormat.totalFrames = audioFormat.totalSamples / audioFormat.channels;

      // Save audio format information as a JSON file
      await fsPromises.writeFile(
        path.join(audioDir, "audio-info.json"),
        JSON.stringify(audioFormat, null, 2)
      );

      console.log(
        `Audio Saved: ${audioFormat.totalFrames} Frames, Total Samples: ${audioFormat.totalSamples}`
      );
    }

    console.log(`Recording Complete - Frames: ${frameCount}`);
    console.log(`Save Location: ${captureDir}`);
  } catch (err) {
    console.error("Test Error:", err);
  } finally {
    // Enhanced capture stop processing (catch capture stop errors)
    if (capture) {
      try {
        console.log("Cleaning Up Resources...");

        // 1. Remove all listeners first (this is important)
        try {
          capture.removeAllListeners();
          console.log("Removed Event Listeners");
        } catch (e) {
          console.error("Listener Removal Error:", e);
        }

        // 2. Call stopCapture with a timeout
        try {
          if (capture.stopCapture) {
            console.log("Starting Capture Stop Processing...");
            const stopPromise = capture.stopCapture();

            if (stopPromise && typeof stopPromise.then === "function") {
              await Promise.race([
                stopPromise,
                new Promise((_, reject) =>
                  setTimeout(
                    () => reject(new Error("Stop Processing Timeout")),
                    1000
                  )
                ),
              ]);
            }
            console.log("Capture Stop Processing Complete");
          }
        } catch (e) {
          console.error("Stop Processing Error (Ignored):", e.message);
        }

        // 3. Explicit garbage collection call
        console.log("Releasing Objects...");
        capture = null;
        if (global.gc) global.gc();
      } catch (err) {
        console.error("Cleanup Error:", err);
      }
    }

    // Explicitly run GC to prevent memory leaks
    console.log("Cleaning Up Memory...");
    if (global.gc) {
      global.gc();
    }
  }
}

// Execute recording (parameter is recording time in milliseconds)
recordCapture(60000)
  .then(() => console.log("Recording Process Complete"))
  .catch((err) => console.error("Unexpected Error:", err))
  .finally(() => {
    // Wait a bit before exiting the process (for resource release)
    setTimeout(() => {
      console.log("Process Exited");
      process.exit(0);
    }, 2000);
  });
