import { MediaCapture } from "../../index.mjs";
import fs from "fs";
import * as fsPromises from "fs/promises";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

if (typeof process.getActiveResourcesInfo === "function") {
  setInterval(() => {
    console.log("アクティブリソース:", process.getActiveResourcesInfo());
  }, 1000);
}

async function recordCapture(durationMs = 5000) {
  console.log("=== メディアキャプチャ記録テスト ===");

  // タイムスタンプベースのフォルダ名を作成
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const captureDir = path.join(__dirname, `../../output/capture_${timestamp}`);
  const imagesDir = path.join(captureDir, "images");
  const audioDir = path.join(captureDir, "audio");

  // フレームカウンター
  let frameCount = 0;

  // オーディオバッファ (Float32Arrayのデータを集める)
  const audioChunks = [];
  let audioFormat = {
    sampleRate: 48000,
    channels: 2,
    bytesPerSample: 4, // f32le format
  };

  // フォルダ作成
  await fsPromises.mkdir(captureDir, { recursive: true });
  await fsPromises.mkdir(imagesDir, { recursive: true });
  await fsPromises.mkdir(audioDir, { recursive: true });

  console.log(`キャプチャディレクトリを作成: ${captureDir}`);

  let capture = null;

  try {
    // キャプチャオブジェクトをクリアに
    if (capture) {
      capture.removeAllListeners();
    }

    // 新規にキャプチャを作成
    capture = new MediaCapture();

    // エラーハンドラを最初に追加
    capture.on("error", (err) => {
      console.error("キャプチャエラー:", err.message);
    });

    // フレームとオーディオデータのカウンタ
    let frameCount = 0;
    let audioSampleCount = 0;

    // ビデオフレーム処理 - エラーハンドリング追加
    capture.on("video-frame", (frame) => {
      try {
        // 基本情報のみ出力（処理負荷軽減）
        if (frameCount % 5 === 0) {
          console.log(
            `フレーム ${frameCount}: ${frame.width}x${frame.height}, ${
              frame.isJpeg ? "JPEG" : "RAW"
            } データ`
          );
        }

        // バリデーション
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

          // 同期メソッド - Node.jsの標準fsモジュールを使用
          fs.writeFileSync(frameFile, Buffer.from(frame.data));
          frameCount++; // 成功した場合のみカウントアップ
        } catch (err) {
          console.error(`フレーム保存エラー: ${err.message}`);
        }
      } catch (err) {
        console.error("フレーム処理エラー:", err);
      }
    });

    // オーディオデータ処理 - エラーハンドリング追加
    capture.on("audio-data", (audioData, sampleRate, channels) => {
      try {
        audioSampleCount += audioData.length;
        if (audioSampleCount % 10000 === 0) {
          console.log(
            `オーディオデータ: ${audioData.length} サンプル, ${channels} チャンネル, ${sampleRate}Hz`
          );
        }

        // 最小限の処理
        console.log(
          `オーディオバッファ受信: ${channels}チャネル, ${
            audioData.length / channels
          }フレーム`
        );

        // バッファをそのまま保存（変換処理を最小限に）
        if (audioData && audioData.buffer) {
          audioChunks.push(Buffer.from(audioData.buffer));
        }
      } catch (err) {
        console.error("オーディオ処理エラー:", err);
      }
    });

    // エラー処理
    capture.on("error", (err) => console.error("キャプチャエラー:", err));

    // キャプチャ設定
    const config = {
      frameRate: 1,
      quality: 0, // High quality
      audioSampleRate: 48000,
      audioChannels: 2,
      displayId: 1, // メインディスプレイのID
    };

    console.log(`${durationMs / 1000}秒間のキャプチャを開始...`);

    // 新しいinterfaceではPromiseではないかもしれないので、エラーハンドリング追加
    try {
      capture.startCapture(config);
    } catch (err) {
      console.error("キャプチャ開始エラー:", err);
      throw err;
    }

    // 指定時間キャプチャ
    await new Promise((resolve) => setTimeout(resolve, durationMs));

    console.log("キャプチャ停止中...");
    try {
      await capture.stopCapture();
    } catch (err) {
      console.error("キャプチャ停止エラー:", err);
    }

    // オーディオデータを1つのファイルに保存
    if (audioChunks.length > 0) {
      const audioFile = path.join(audioDir, "audio.f32le");
      const audioData = Buffer.concat(audioChunks);
      await fsPromises.writeFile(audioFile, audioData);

      // フレーム数をフォーマット情報に追加
      audioFormat.totalSamples = audioData.length / audioFormat.bytesPerSample;
      audioFormat.totalFrames = audioFormat.totalSamples / audioFormat.channels;

      // オーディオ形式情報をJSONファイルとして保存
      await fsPromises.writeFile(
        path.join(audioDir, "audio-info.json"),
        JSON.stringify(audioFormat, null, 2)
      );

      console.log(
        `オーディオ保存完了: ${audioFormat.totalFrames} フレーム、総サンプル数: ${audioFormat.totalSamples}`
      );
    }

    console.log(`記録完了 - フレーム数: ${frameCount}`);
    console.log(`保存先: ${captureDir}`);
  } catch (err) {
    console.error("テストエラー:", err);
  } finally {
    // キャプチャ停止処理の強化（キャプチャ停止エラーをキャッチ）
    if (capture) {
      try {
        console.log("リソースクリーンアップ中...");

        // 1. まず全てのリスナーを削除（これが重要）
        try {
          capture.removeAllListeners();
          console.log("イベントリスナーを削除しました");
        } catch (e) {
          console.error("リスナー削除エラー:", e);
        }

        // 2. stopCaptureをタイムアウトと一緒に呼び出し
        try {
          if (capture.stopCapture) {
            console.log("キャプチャ停止処理を開始...");
            const stopPromise = capture.stopCapture();

            if (stopPromise && typeof stopPromise.then === "function") {
              await Promise.race([
                stopPromise,
                new Promise((_, reject) =>
                  setTimeout(
                    () => reject(new Error("停止処理タイムアウト")),
                    1000
                  )
                ),
              ]);
            }
            console.log("キャプチャ停止処理完了");
          }
        } catch (e) {
          console.error("停止処理エラー（無視）:", e.message);
        }

        // 3. 明示的なガベージコレクション呼び出し
        console.log("オブジェクトを解放中...");
        capture = null;
        if (global.gc) global.gc();
      } catch (err) {
        console.error("クリーンアップエラー:", err);
      }
    }

    // メモリリークを防止するためにGCを明示的に実行
    console.log("メモリクリーンアップ中...");
    if (global.gc) {
      global.gc();
    }
  }
}

// 記録実行（パラメータは記録時間（ミリ秒））
recordCapture(2000)
  .then(() => console.log("記録プロセス完了"))
  .catch((err) => console.error("予期せぬエラー:", err))
  .finally(() => {
    // プロセス終了前に少し待つ（リソース解放のため）
    setTimeout(() => {
      console.log("プロセス終了");
      process.exit(0);
    }, 2000);
  });
