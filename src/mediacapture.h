#ifndef MEDIA_CAPTURE_H
#define MEDIA_CAPTURE_H

#include <napi.h>
#include <mutex>
#include <thread>
#include <atomic>
#include <vector>
#include "../include/capture/capture.h"

// コンテキスト構造体をクラスの外部で定義
struct CaptureContext {
  class MediaCapture* instance;
  Napi::Promise::Deferred deferred;
};

struct StopContext {
  class MediaCapture* instance;
  Napi::Promise::Deferred deferred;
};

class MediaCapture : public Napi::ObjectWrap<MediaCapture> {
 public:
  static Napi::Object Init(Napi::Env env, Napi::Object exports);
  MediaCapture(const Napi::CallbackInfo& info);
  ~MediaCapture();

 private:
  static Napi::Value EnumerateTargets(const Napi::CallbackInfo& info);
  Napi::Value StartCapture(const Napi::CallbackInfo& info);
  Napi::Value StopCapture(const Napi::CallbackInfo& info);

  // ネイティブリソースへのハンドル
  void* captureHandle_;
  
  // キャプチャ状態管理
  std::atomic<bool> isCapturing_;
  
  // イベント発行のための参照
  Napi::ThreadSafeFunction tsfn_video_;
  Napi::ThreadSafeFunction tsfn_audio_;
  Napi::ThreadSafeFunction tsfn_error_;
  
  // キャプチャコールバック
  static void VideoFrameCallback(uint8_t* data, int32_t width, int32_t height, 
                             int32_t bytesPerRow, int32_t timestamp, void* ctx);
  static void AudioDataCallback(int32_t channels, int32_t sampleRate, 
                             float* buffer, int32_t frameCount, void* ctx);
  static void ExitCallback(char* error, void* ctx);
  static void StopCallback(void* ctx);
};

#endif // MEDIA_CAPTURE_H