import { MediaCapture } from "../../index.mjs";

// MediaCaptureQualityを直接定義
const MediaCaptureQuality = {
  High: 0,
  Medium: 1,
  Low: 2,
};

// 未処理の例外をキャッチ
process.on("uncaughtException", (err) => {
  console.error("未処理の例外が発生しました:", err);
});

process.on("unhandledRejection", (reason, promise) => {
  console.error("未処理のPromise拒否が発生しました:", reason);
});

async function testMediaCapture() {
  console.log("Testing MediaCapture via index.mjs...");

  try {
    console.log("Creating MediaCapture instance...");
    const capture = new MediaCapture();
    console.log("MediaCapture instance created successfully");

    let videoFrameCount = 0;
    let audioDataCount = 0;
    let startTime = null;

    // ビデオフレームイベントリスナー
    capture.on("videoframe", (frame) => {
      if (startTime === null) {
        startTime = Date.now();
      }

      videoFrameCount++;

      // 出力頻度を制限
      if (videoFrameCount % 30 === 0) {
        // 約1秒ごと（30fpsの場合）
        const elapsedSeconds = (Date.now() - startTime) / 1000;
        const rate = videoFrameCount / elapsedSeconds;
        console.log(
          `Received ${videoFrameCount} video frames (${frame.width}x${
            frame.height
          }, ${frame.data.length} bytes) - Rate: ${rate.toFixed(1)} fps`
        );
      }
    });

    // オーディオデータイベントリスナー
    capture.on("audiodata", (audio) => {
      audioDataCount++;

      // 出力頻度を制限
      if (audioDataCount % 100 === 0) {
        console.log(
          `Received ${audioDataCount} audio data blocks (${audio.channels} channels, ${audio.data.length} samples, ${audio.sampleRate} Hz)`
        );
      }
    });

    // エラーイベントリスナー
    capture.on("error", (err) => {
      console.error("Capture error:", err);
    });

    // 終了イベントリスナー
    capture.on("exit", () => {
      console.log("Capture exited");
    });

    // 最小限の機能だけをテスト
    console.log("Enumerating media capture targets...");
    try {
      const targets = await MediaCapture.enumerateMediaCaptureTargets();
      console.log(`Enumeration completed. Found ${targets.length} targets`);

      // ターゲット情報を表示
      targets.forEach((target, i) => {
        console.log(
          `Target ${i + 1}: ${target.isDisplay ? "Display" : "Window"} ID=${
            target.isDisplay ? target.displayId : target.windowId
          }`
        );
      });

      if (targets.length === 0) {
        console.error("No targets available for capture");
        return;
      }

      // 最初のターゲット（通常はメインディスプレイ）を選択
      const captureTarget = targets[0];
      console.log(
        `Starting capture on ${
          captureTarget.isDisplay ? "display" : "window"
        } ID ${
          captureTarget.isDisplay
            ? captureTarget.displayId
            : captureTarget.windowId
        }`
      );

      // キャプチャ設定
      const config = {
        frameRate: 30,
        quality: MediaCaptureQuality.Medium, // 中品質でテスト
        audioSampleRate: 48000,
        audioChannels: 2,
      };

      // ディスプレイかウィンドウかに応じてIDを設定
      if (captureTarget.isDisplay) {
        config.displayId = captureTarget.displayId;
      } else {
        config.windowId = captureTarget.windowId;
      }

      // キャプチャ開始
      console.log("Starting capture with config:", config);
      capture.startCapture(config);
      console.log("Capture started successfully");

      // 指定時間後に停止
      const captureTime = 10000; // 10秒
      console.log(`Recording for ${captureTime / 1000} seconds...`);

      await new Promise((resolve) => setTimeout(resolve, captureTime));

      // キャプチャ停止
      console.log("Stopping capture...");
      await capture.stopCapture();

      // 統計情報の出力
      if (startTime !== null) {
        const totalTime = (Date.now() - startTime) / 1000;
        console.log(
          `Capture complete: ${videoFrameCount} video frames and ${audioDataCount} audio blocks received in ${totalTime.toFixed(
            2
          )} seconds`
        );
        console.log(
          `Average video rate: ${(videoFrameCount / totalTime).toFixed(
            1
          )} frames/second`
        );
        console.log(
          `Average audio rate: ${(audioDataCount / totalTime).toFixed(
            1
          )} blocks/second`
        );
      } else {
        console.log("No media data was received during capture");
      }

      // クリーンアップ
      capture.removeAllListeners();
    } catch (enumError) {
      console.error("Error during enumeration:", enumError);
    }
  } catch (err) {
    console.error("Test error:", err);
  } finally {
    console.log("Test completed");
  }
}

// メイン処理の実行
console.log("Starting test...");
testMediaCapture()
  .then(() => console.log("Test finished successfully"))
  .catch((err) => {
    console.error("Test failed with error:", err);
  })
  .finally(() => {
    console.log("Test execution complete");
    // タイムアウトを設定して、Node.jsプロセスがハングしないようにする
    setTimeout(() => {
      console.log("Forcing exit after timeout");
      process.exit(0);
    }, 3000);
  });
