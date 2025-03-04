import { AudioCapture } from "../../index.mjs";
import fs from "fs/promises";
import path from "path";

async function captureAudioToPCM() {
  console.log("=== 画面音声キャプチャテスト ===");

  // 音声設定
  const audioConfig = {
    sampleRate: 48000,
    channels: 2,
  };

  // サンプルコードと同様に配列として音声データを蓄積
  let audioBuffer = [];
  let captureStartTime = null;
  let captureEndTime = null;

  try {
    // AudioCaptureインスタンスを作成
    const capture = new AudioCapture();

    // 利用可能なディスプレイとウィンドウを列挙（先に実行）
    console.log("画面情報を取得中...");
    const [displays, windows] = await AudioCapture.enumerateDesktopWindows();
    console.log(
      `ディスプレイ: ${displays.length}個, ウィンドウ: ${windows.length}個`
    );

    if (displays.length === 0) {
      console.error("キャプチャ可能なディスプレイがありません");
      return;
    }

    // サンプルコードと同様のデータハンドラを実装
    capture.on("data", (buffer) => {
      // バッファからFloat32Arrayを作成（これがサンプルコードと同じアプローチ）
      const float32Array = new Float32Array(buffer);

      // 配列に直接追加（サンプルコードから移植）
      audioBuffer.push(...float32Array);

      if (captureStartTime === null) {
        captureStartTime = Date.now();
        console.log("最初のオーディオデータを受信しました");
      }

      // 進捗表示（シンプルに100ms毎）
      if (audioBuffer.length % 4800 === 0) {
        // 100ms相当（48000Hz × 0.1秒 = 4800サンプル）
        const elapsedSeconds = (Date.now() - captureStartTime) / 1000;
        const bufferSizeKb = (audioBuffer.length * 4) / 1024;
        console.log(
          `録音中: ${elapsedSeconds.toFixed(
            1
          )}秒 / 10秒 (${bufferSizeKb.toFixed(0)}KB) サンプル数: ${
            audioBuffer.length
          }`
        );

        // サンプルの範囲をチェック（データ検証）
        const lastChunk = float32Array.slice(
          0,
          Math.min(10, float32Array.length)
        );
        const hasSoundData = lastChunk.some((v) => Math.abs(v) > 0.01);
        if (hasSoundData) {
          console.log(
            "音声データあり: ",
            Array.from(lastChunk.slice(0, 3)).map((v) => v.toFixed(4))
          );
        }
      }
    });

    // エラー処理
    capture.on("error", (err) => {
      console.error("キャプチャエラー:", err);
    });

    // メインディスプレイを選択
    const displayTarget = displays[0];
    console.log(
      `メインディスプレイ (ID: ${displayTarget.displayId}) のキャプチャを開始します`
    );

    // サンプルコードと同様のキャプチャ設定
    const config = {
      displayId: displayTarget.displayId,
      windowId: 0,
      channels: audioConfig.channels,
      sampleRate: audioConfig.sampleRate,
    };

    // キャプチャ開始
    console.log("キャプチャを開始します...");
    await capture.startCapture(config);
    console.log("キャプチャ開始完了");

    // 10秒間待機
    const captureTime = 10000; // 10秒
    console.log(`${captureTime / 1000}秒間録音します...`);
    await new Promise((resolve) => setTimeout(resolve, captureTime));

    // キャプチャ停止
    console.log("キャプチャを停止します...");
    await capture.stopCapture();
    captureEndTime = Date.now();
    console.log("キャプチャ停止完了");

    // 結果を処理
    if (audioBuffer.length > 0) {
      const duration = (captureEndTime - captureStartTime) / 1000;
      console.log(`録音完了: サンプル数: ${audioBuffer.length}`);

      // Float32Arrayに変換
      const finalFloat32Array = new Float32Array(audioBuffer);

      // Bufferに変換
      const finalBuffer = Buffer.from(finalFloat32Array.buffer);

      // ファイル名を作成
      const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
      const outputDir = path.join(process.cwd(), "output");
      await fs.mkdir(outputDir, { recursive: true });

      // PCMファイルのパス
      const pcmFilePath = path.join(
        outputDir,
        `audio-capture-${timestamp}.f32le`
      );

      // PCMファイルを保存
      await fs.writeFile(pcmFilePath, finalBuffer);
      console.log(`PCMファイル保存完了: ${pcmFilePath}`);

      // メタデータを保存
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

      console.log(`=== キャプチャ完了 ===`);
      console.log(`Float32 PCMファイル: ${pcmFilePath}`);
      console.log(`メタデータ: ${metadataFilePath}`);
      console.log(
        `ファイルサイズ: ${(finalBuffer.length / 1024 / 1024).toFixed(2)} MB`
      );
      console.log(`録音時間: ${duration.toFixed(2)}秒`);
      console.log(`予想再生時間: ${expectedDuration.toFixed(2)}秒`);
      console.log(`総サンプル数: ${audioBuffer.length}`);
      console.log(`チャンネル数: ${audioConfig.channels}`);
      console.log(`サンプルレート: ${audioConfig.sampleRate} Hz`);
      console.log(`\n再生コマンド:`);
      console.log(
        `ffplay -f f32le -ar ${audioConfig.sampleRate} -ch_layout stereo "${pcmFilePath}"`
      );
    } else {
      console.log("音声データを受信できませんでした。以下を確認してください：");
      console.log("- システム音声が出ていること");
      console.log("- 画面キャプチャの権限が許可されていること");
      console.log("- メインディスプレイが正しく選択されていること");
    }

    // クリーンアップ
    capture.removeAllListeners();
  } catch (err) {
    console.error("テストエラー:", err);
  }
}

// メイン処理の実行
captureAudioToPCM().catch((err) => {
  console.error("未処理のエラー:", err);
  process.exit(1);
});
