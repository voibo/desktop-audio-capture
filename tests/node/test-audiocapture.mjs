import { AudioCapture } from "../../index.mjs";
import fs from "fs/promises";
import path from "path";

async function captureAudioToPCM() {
  console.log("=== Audio Capture Test ===");

  // Audio settings
  const audioConfig = {
    sampleRate: 48000,
    channels: 2,
  };

  // Accumulate audio data as an array, similar to the sample code
  let audioBuffer = [];
  let captureStartTime = null;
  let captureEndTime = null;

  try {
    // Create AudioCapture instance
    const capture = new AudioCapture();

    // Enumerate available displays and windows (execute first)
    console.log("Retrieving screen information...");
    const [displays, windows] = await AudioCapture.enumerateDesktopWindows();
    console.log(`Displays: ${displays.length}, Windows: ${windows.length}`);

    if (displays.length === 0) {
      console.error("No capturable displays available");
      return;
    }

    // Implement the same data handler as the sample code
    capture.on("data", (buffer) => {
      // Create Float32Array from the buffer (same approach as the sample code)
      const float32Array = new Float32Array(buffer);

      // Add directly to the array (ported from the sample code)
      audioBuffer.push(...float32Array);

      if (captureStartTime === null) {
        captureStartTime = Date.now();
        console.log("Received first audio data");
      }

      // Progress display (simply every 100ms)
      if (audioBuffer.length % 4800 === 0) {
        // Equivalent to 100ms (48000Hz × 0.1 seconds = 4800 samples)
        const elapsedSeconds = (Date.now() - captureStartTime) / 1000;
        const bufferSizeKb = (audioBuffer.length * 4) / 1024;
        console.log(
          `Recording: ${elapsedSeconds.toFixed(
            1
          )} seconds / 10 seconds (${bufferSizeKb.toFixed(0)}KB) Samples: ${
            audioBuffer.length
          }`
        );

        // Check the range of samples (data validation)
        const lastChunk = float32Array.slice(
          0,
          Math.min(10, float32Array.length)
        );
        const hasSoundData = lastChunk.some((v) => Math.abs(v) > 0.01);
        if (hasSoundData) {
          console.log(
            "Audio data present: ",
            Array.from(lastChunk.slice(0, 3)).map((v) => v.toFixed(4))
          );
        }
      }
    });

    // Error handling
    capture.on("error", (err) => {
      console.error("Capture error:", err);
    });

    // Select the main display
    const displayTarget = displays[0];
    console.log(
      `Starting capture of the main display (ID: ${displayTarget.displayId})`
    );

    // Same capture settings as the sample code
    const config = {
      displayId: displayTarget.displayId,
      windowId: 0,
      channels: audioConfig.channels,
      sampleRate: audioConfig.sampleRate,
    };

    // Start capture
    console.log("Starting capture...");
    await capture.startCapture(config);
    console.log("Capture start complete");

    // Wait for 10 seconds
    const captureTime = 10000; // 10 seconds
    console.log(`Recording for ${captureTime / 1000} seconds...`);
    await new Promise((resolve) => setTimeout(resolve, captureTime));

    // Stop capture
    console.log("Stopping capture...");
    await capture.stopCapture();
    captureEndTime = Date.now();
    console.log("Capture stop complete");

    // Process the results
    if (audioBuffer.length > 0) {
      const duration = (captureEndTime - captureStartTime) / 1000;
      console.log(`Recording complete: Samples: ${audioBuffer.length}`);

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

      console.log(`=== Capture Complete ===`);
      console.log(`Float32 PCM File: ${pcmFilePath}`);
      console.log(`Metadata: ${metadataFilePath}`);
      console.log(
        `File Size: ${(finalBuffer.length / 1024 / 1024).toFixed(2)} MB`
      );
      console.log(`Recording Time: ${duration.toFixed(2)} seconds`);
      console.log(`Expected Play Time: ${expectedDuration.toFixed(2)} seconds`);
      console.log(`Total Samples: ${audioBuffer.length}`);
      console.log(`Channels: ${audioConfig.channels}`);
      console.log(`Sample Rate: ${audioConfig.sampleRate} Hz`);
      console.log(`\nPlayback Command:`);
      console.log(
        `ffplay -f f32le -ar ${audioConfig.sampleRate} -ch_layout stereo "${pcmFilePath}"`
      );
    } else {
      console.log("No audio data received. Please check the following:");
      console.log("- System audio is playing");
      console.log("- Screen capture permissions are allowed");
      console.log("- The main display is selected correctly");
    }

    // Cleanup
    capture.removeAllListeners();
  } catch (err) {
    console.error("Test error:", err);
  }
}

// Execute main process
captureAudioToPCM().catch((err) => {
  console.error("Unhandled error:", err);
  process.exit(1);
});
