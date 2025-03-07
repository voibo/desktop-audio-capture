import {
  MediaCapture,
  MediaCaptureQuality,
} from "@voibo/desktop-audio-capture";
import fs from "fs";
import * as fsPromises from "fs/promises";
import path from "path";

console.log("Desktop Audio Capture Sample - MediaCapture");

// Apple Siliconかどうかをチェック
const isAppleSilicon =
  process.platform === "darwin" && process.arch === "arm64";

if (!isAppleSilicon) {
  console.warn(
    "MediaCaptureはApple Silicon (ARM64) macOSデバイスでのみ利用可能です。"
  );
  process.exit(1);
}

async function recordCapture(durationMs = 5000) {
  console.log("=== メディアキャプチャ録画テスト ===");

  // タイムスタンプベースのフォルダ名を作成
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const captureDir = path.join(process.cwd(), `output/capture_${timestamp}`);
  const imagesDir = path.join(captureDir, "images");
  const audioDir = path.join(captureDir, "audio");

  // フレームカウンタ
  let frameCount = 0;

  // オーディオバッファ（Float32Arrayデータを収集）
  const audioChunks = [];
  let audioFormat = {
    sampleRate: 48000,
    channels: 2,
    bytesPerSample: 4, // f32le形式
  };

  // フォルダを作成
  await fsPromises.mkdir(captureDir, { recursive: true });
  await fsPromises.mkdir(imagesDir, { recursive: true });
  await fsPromises.mkdir(audioDir, { recursive: true });

  console.log(`キャプチャディレクトリを作成: ${captureDir}`);

  let capture = null;

  try {
    // キャプチャオブジェクトをクリア
    if (capture) {
      capture.removeAllListeners();
    }

    // 新しいキャプチャを作成
    capture = new MediaCapture();

    // 最初にエラーハンドラを追加
    capture.on("error", (err) => {
      console.error("キャプチャエラー:", err.message);
    });

    // フレームとオーディオデータのカウンタ
    let frameCount = 0;
    let audioSampleCount = 0;

    // ビデオフレーム処理
    capture.on("video-frame", (frame) => {
      try {
        // 基本情報のみ出力（処理負荷を軽減）
        if (frameCount % 5 === 0) {
          console.log(
            `フレーム ${frameCount}: ${frame.width}x${frame.height}, ${
              frame.isJpeg ? "JPEG" : "RAW"
            } データ`
          );
        }

        // 検証
        if (!frame || !frame.data) {
          console.error(
            `無効なフレーム: ${frame ? "データなし" : "フレームなし"}`
          );
          return;
        }

        try {
          const frameFile = path.join(
            imagesDir,
            `frame_${String(frameCount).padStart(5, "0")}.jpg`
          );

          // 同期メソッド - Node.js標準fsモジュールを使用
          fs.writeFileSync(frameFile, Buffer.from(frame.data));
          frameCount++; // 成功した場合のみカウントを増やす
        } catch (err) {
          console.error(`フレーム保存エラー: ${err.message}`);
        }
      } catch (err) {
        console.error("フレーム処理エラー:", err);
      }
    });

    // オーディオデータ処理
    capture.on("audio-data", (audioData, sampleRate, channels) => {
      try {
        audioSampleCount += audioData.length;
        if (audioSampleCount % 10000 === 0) {
          console.log(
            `オーディオデータ: ${audioData.length} サンプル, ${channels} チャンネル, ${sampleRate}Hz`
          );
        }

        // バッファをそのまま保存
        if (audioData && audioData.buffer) {
          audioChunks.push(Buffer.from(audioData.buffer));
        }
      } catch (err) {
        console.error("オーディオ処理エラー:", err);
      }
    });

    // 利用可能なターゲットを列挙
    const targets = await MediaCapture.enumerateMediaCaptureTargets();
    console.log("利用可能なキャプチャターゲット:");
    targets.forEach((target, index) => {
      console.log(
        `[${index}] ${target.title || "Untitled"} (${
          target.isDisplay ? "ディスプレイ" : "ウィンドウ"
        })`
      );
      console.log(
        `    displayId: ${target.displayId}, windowId: ${target.windowId}`
      );
    });

    if (targets.length === 0) {
      console.error("利用可能なキャプチャターゲットがありません");
      return;
    }

    // ターゲットのIDを取得 - 最初のディスプレイを選択
    const displayTarget = targets.find((t) => t.isDisplay) || targets[0];

    // キャプチャ設定 - 修正: targetIdではなくdisplayIdを使用
    const config = {
      displayId: displayTarget.displayId, // targetIdではなくdisplayIdを使用
      frameRate: 1,
      quality: MediaCaptureQuality.High,
      audioSampleRate: 16000,
      audioChannels: 1,
    };

    console.log(`${durationMs / 1000}秒間のキャプチャを開始...`);
    console.log(
      `選択したターゲット: ${displayTarget.title || "Untitled"} (displayId: ${
        displayTarget.displayId
      })`
    );

    // キャプチャ開始
    try {
      capture.startCapture(config);
    } catch (err) {
      console.error("キャプチャ開始エラー:", err);
      throw err;
    }

    // 指定された時間キャプチャ
    await new Promise((resolve) => setTimeout(resolve, durationMs));

    console.log("キャプチャを停止中...");
    try {
      await capture.stopCapture();
    } catch (err) {
      console.error("キャプチャ停止エラー:", err);
    }

    // オーディオデータを単一ファイルに保存
    if (audioChunks.length > 0) {
      const audioFile = path.join(audioDir, "audio.f32le");
      const audioData = Buffer.concat(audioChunks);
      await fsPromises.writeFile(audioFile, audioData);

      // フレーム数をフォーマット情報に追加
      audioFormat.totalSamples = audioData.length / audioFormat.bytesPerSample;
      audioFormat.totalFrames = audioFormat.totalSamples / audioFormat.channels;

      // オーディオフォーマット情報をJSONファイルとして保存
      await fsPromises.writeFile(
        path.join(audioDir, "audio-info.json"),
        JSON.stringify(audioFormat, null, 2)
      );

      console.log(
        `オーディオ保存完了: ${audioFormat.totalFrames}フレーム, 総サンプル数: ${audioFormat.totalSamples}`
      );
    }

    console.log(`録画完了 - フレーム数: ${frameCount}`);
    console.log(`保存場所: ${captureDir}`);
    console.log(
      `オーディオ再生コマンド: ffplay -f f32le -ar ${
        audioFormat.sampleRate
      } -ch_layout stereo "${path.join(audioDir, "audio.f32le")}"`
    );
  } catch (err) {
    console.error("テストエラー:", err);
  } finally {
    // 強化されたキャプチャ停止処理
    if (capture) {
      try {
        console.log("リソースをクリーンアップ中...");

        // リスナーを削除
        try {
          capture.removeAllListeners();
          console.log("イベントリスナーを削除しました");
        } catch (e) {
          console.error("リスナー削除エラー:", e);
        }

        // 停止処理
        try {
          if (capture.stopCapture) {
            console.log("キャプチャ停止処理を開始...");
            capture.stopCapture();
            console.log("キャプチャ停止処理完了");
          }
        } catch (e) {
          console.error("停止処理エラー（無視）:", e.message);
        }

        // 明示的なガベージコレクション
        console.log("オブジェクトを解放中...");
        capture = null;
      } catch (err) {
        console.error("クリーンアップエラー:", err);
      }
    }
  }
}

async function run() {
  try {
    await recordCapture(5000);
    console.log("録画プロセス完了");
  } catch (err) {
    console.error("予期せぬエラー:", err);
  } finally {
    // リソース解放のため待機
    setTimeout(() => {
      console.log("プロセス終了");
      process.exit(0);
    }, 2000);
  }
}

run();
