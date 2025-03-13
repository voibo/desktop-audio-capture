import { AudioCapture } from "@voibo/desktop-audio-capture";
import fs from "fs/promises";
import path from "path";

console.log("Desktop Audio Capture Sample - AudioCapture");

// audio-sample.mjsにデバッグ情報を追加
console.log("システム情報:", {
  nodeVersion: process.version,
  platform: process.platform,
  arch: process.arch,
  pid: process.pid,
  execPath: process.execPath
});

async function captureAudioToPCM() {
  // プラットフォームに応じてチャンネル設定を調整
  const isWindows = process.platform === "win32";
  
  // オーディオ設定を調整
  const audioConfig = {
    sampleRate: 44100,  // 48000から44100に変更
    channels: isWindows ? 1 : 2, // Windowsでは1チャンネル、macOSでは2チャンネル
  };

  console.log(`プラットフォーム: ${process.platform}, チャンネル数: ${audioConfig.channels}`);

  // オーディオデータの累積用配列
  let audioBuffer = [];
  let captureStartTime = null;
  let captureEndTime = null;

  try {
    // オーディオキャプチャのインスタンスを作成
    const audioCapture = new AudioCapture();

    // 利用可能なディスプレイとウィンドウを列挙
    console.log("画面情報を取得中...");
    const [displays, windows] = await AudioCapture.enumerateDesktopWindows();
    console.log(
      `ディスプレイ: ${displays.length}、ウィンドウ: ${windows.length}`
    );

    if (displays.length === 0) {
      console.error("キャプチャ可能なディスプレイがありません");
      return;
    }

    // イベントリスナーを設定
    audioCapture.on("data", (buffer) => {
      // バッファからFloat32Arrayを作成
      const float32Array = new Float32Array(buffer);

      // 配列に直接追加
      audioBuffer.push(...float32Array);

      if (captureStartTime === null) {
        captureStartTime = Date.now();
        console.log("最初のオーディオデータを受信");
      }

      // 進捗表示（100ms毎）
      if (audioBuffer.length % 4800 === 0) {
        // 100ms相当 (48000Hz × 0.1秒 = 4800サンプル)
        const elapsedSeconds = (Date.now() - captureStartTime) / 1000;
        const bufferSizeKb = (audioBuffer.length * 4) / 1024;
        console.log(
          `録音中: ${elapsedSeconds.toFixed(1)}秒 / 5秒 (${bufferSizeKb.toFixed(
            0
          )}KB) サンプル数: ${audioBuffer.length}`
        );

        // サンプルの範囲チェック（データ検証）
        const lastChunk = float32Array.slice(
          0,
          Math.min(10, float32Array.length)
        );
        const hasSoundData = lastChunk.some((v) => Math.abs(v) > 0.01);
        if (hasSoundData) {
          console.log(
            "音声データ検出: ",
            Array.from(lastChunk.slice(0, 3)).map((v) => v.toFixed(4))
          );
        }
      }
    });

    audioCapture.on("error", (err) => {
      console.error("キャプチャエラー:", err);
    });

    // メインディスプレイを選択
    const displayTarget = displays[0];
    console.log(
      `メインディスプレイのキャプチャを開始 (ID: ${displayTarget.displayId})`
    );

    // キャプチャ設定
    const config = {
      displayId: displayTarget.displayId,
      windowId: 0,
      channels: audioConfig.channels,
      sampleRate: audioConfig.sampleRate,
    };

    // キャプチャ開始
    console.log("キャプチャを開始...");
    await audioCapture.startCapture(config);
    console.log("キャプチャ開始完了");

    // 5秒間待機
    const captureTime = 5000; // 5秒
    console.log(`${captureTime / 1000}秒間録音中...`);
    await new Promise((resolve) => setTimeout(resolve, captureTime));

    // キャプチャ停止
    console.log("キャプチャを停止...");
    await audioCapture.stopCapture();
    captureEndTime = Date.now();
    console.log("キャプチャ停止完了");

    // 結果の処理
    if (audioBuffer.length > 0) {
      const duration = (captureEndTime - captureStartTime) / 1000;
      console.log(`録音完了: サンプル数: ${audioBuffer.length}`);

      // Float32Arrayに変換
      const finalFloat32Array = new Float32Array(audioBuffer);

      // Bufferに変換
      const finalBuffer = Buffer.from(finalFloat32Array.buffer);

      // ファイル名の作成
      const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
      const outputDir = path.join(process.cwd(), "output");
      await fs.mkdir(outputDir, { recursive: true });

      // PCMファイルパス
      const pcmFilePath = path.join(
        outputDir,
        `audio-capture-${timestamp}.f32le`
      );

      // PCMファイルの保存
      await fs.writeFile(pcmFilePath, finalBuffer);
      console.log(`PCMファイル保存: ${pcmFilePath}`);

      // メタデータの保存
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

      // メタデータファイルの保存
      await fs.writeFile(metadataFilePath, JSON.stringify(metadata, null, 2));

      console.log(`=== キャプチャ完了 ===`);
      console.log(`Float32 PCMファイル: ${pcmFilePath}`);
      console.log(`メタデータ: ${metadataFilePath}`);
      console.log(
        `ファイルサイズ: ${(finalBuffer.length / 1024 / 1024).toFixed(2)} MB`
      );
      console.log(`録音時間: ${duration.toFixed(2)}秒`);
      console.log(`再生予想時間: ${expectedDuration.toFixed(2)}秒`);
      console.log(`総サンプル数: ${audioBuffer.length}`);
      console.log(`チャンネル数: ${audioConfig.channels}`);
      console.log(`サンプルレート: ${audioConfig.sampleRate} Hz`);
      console.log(`\n再生コマンド:`);
      console.log(
        `ffplay -f f32le -ar ${audioConfig.sampleRate} -ch_layout ${audioConfig.channels == 1 ? "mono" : "stereo"} "${pcmFilePath}"`
      );
    } else {
      console.log(
        "オーディオデータを受信できませんでした。以下を確認してください:"
      );
      console.log("- システムオーディオが再生されていること");
      console.log("- 画面キャプチャの権限が許可されていること");
      console.log("- メインディスプレイが正しく選択されていること");
    }

    // クリーンアップ
    audioCapture.removeAllListeners();
  } catch (err) {
    console.error("テストエラー:", err);
  }
}

// メイン処理の実行
captureAudioToPCM().catch((err) => {
  console.error("未処理のエラー:", err);
  process.exit(1);
});

// クリーンアップ処理
process.on("SIGINT", () => {
  console.log("中断されました。クリーンアップ中...");
  process.exit(0);
});
