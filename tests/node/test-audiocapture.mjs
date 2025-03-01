import { AudioCapture } from "../../index.mjs";

async function testAudioCapture() {
  console.log("Testing AudioCapture via index.mjs...");

  try {
    const capture = new AudioCapture();
    let sampleCount = 0;
    let startTime = null;

    // データイベントリスナー
    capture.on("data", (buffer) => {
      if (startTime === null) {
        startTime = Date.now();
      }

      sampleCount++;

      // 出力頻度を制限
      if (sampleCount % 100 === 0) {
        const elapsedSeconds = (Date.now() - startTime) / 1000;
        const rate = sampleCount / elapsedSeconds;
        console.log(
          `Received ${sampleCount} audio samples (${
            buffer.length
          } bytes) - Rate: ${rate.toFixed(1)}/sec`
        );
      }
    });

    // エラーイベントリスナー
    capture.on("error", (err) => {
      console.error("Capture error:", err);
    });

    // 重要な修正: enumerateDesktopWindowsは静的メソッド
    console.log("Enumerating desktop windows using static method...");
    const [displays, windows] = await AudioCapture.enumerateDesktopWindows();

    console.log(
      `Found ${displays.length} displays and ${windows.length} windows`
    );

    if (displays.length === 0) {
      console.error("No displays available for capture");
      return;
    }

    // 最初のディスプレイに対してキャプチャ開始
    const displayTarget = displays[0];
    console.log(`Starting capture on display ID ${displayTarget.displayId}`);

    // TypeScriptの定義に合わせたキー名に修正
    const config = {
      displayId: displayTarget.displayId,
      windowId: 0,
      channels: 2, // ステレオでテスト
      sampleRate: 44100, // 標準サンプルレート
    };

    // キャプチャ開始
    console.log("Starting capture...");
    capture.startCapture(config);
    console.log("Capture started successfully");

    // 指定時間後に停止
    const captureTime = 5000; // 5秒
    console.log(`Recording for ${captureTime / 1000} seconds...`);

    await new Promise((resolve) => setTimeout(resolve, captureTime));

    // キャプチャ停止
    console.log("Stopping capture...");
    await capture.stopCapture();

    // 統計情報の出力
    if (startTime !== null) {
      const totalTime = (Date.now() - startTime) / 1000;
      console.log(
        `Capture complete: ${sampleCount} samples received in ${totalTime.toFixed(
          2
        )} seconds`
      );
      console.log(
        `Average rate: ${(sampleCount / totalTime).toFixed(1)} samples/second`
      );
    } else {
      console.log("No audio samples were received during capture");
    }

    // クリーンアップ
    capture.removeAllListeners();
  } catch (err) {
    console.error("Test error:", err.stack || err);
  }
}

// メイン処理の実行
testAudioCapture().catch((err) => {
  console.error("Unhandled error:", err);
  process.exit(1);
});
