import {
  MediaCapture,
  MediaCaptureQuality,
} from "@voibo/desktop-audio-capture";

console.log("MediaCapture Simple Test");

// 基本的なMediaCaptureテスト（ターゲット列挙なし）
async function simpleTest() {
  try {
    // インスタンス作成
    const capture = new MediaCapture();

    // 最小限のイベントハンドラ
    capture.on("error", (err) => {
      console.error("エラー:", err);
    });

    capture.on("video-frame", () => {
      console.log("フレーム受信");
    });

    capture.on("audio-data", () => {
      console.log("オーディオ受信");
    });

    // 固定ターゲットIDでキャプチャを開始
    // 注: スクリーン全体を示す一般的なIDを使用
    console.log("キャプチャ開始...");
    capture.startCapture({
      targetId: "display-0", // デフォルトの画面IDを想定
      quality: MediaCaptureQuality.Medium,
    });

    // 3秒間待機
    await new Promise((resolve) => setTimeout(resolve, 3000));

    // キャプチャ停止
    console.log("キャプチャ停止...");
    capture.stopCapture();

    console.log("テスト完了");
  } catch (err) {
    console.error("テスト失敗:", err);
  }
}

simpleTest().catch(console.error);
