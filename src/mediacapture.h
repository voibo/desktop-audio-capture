#ifndef MEDIA_CAPTURE_H
#define MEDIA_CAPTURE_H

#include <napi.h>
#include <mutex>
#include <thread>
#include <atomic>
#include <vector>
#include <memory>
#include <cstring>
#include <stdexcept>
#include "../include/capture/capture.h"

// 先に前方宣言
class MediaCapture;

struct ContextBase {
  MediaCapture* instance;  // weak_ptrをシンプルなポインタに変更
  
  // コンストラクタ
  ContextBase(MediaCapture* inst) : instance(inst) {}
  virtual ~ContextBase() = default;
};

struct CaptureContext : public ContextBase {
  Napi::Promise::Deferred deferred;
  
  CaptureContext(MediaCapture* inst, Napi::Promise::Deferred def) 
    : ContextBase(inst), deferred(std::move(def)) {}
};

struct StopContext : public ContextBase {
  Napi::Promise::Deferred deferred;
  
  StopContext(MediaCapture* inst, Napi::Promise::Deferred def) 
    : ContextBase(inst), deferred(std::move(def)) {}
};

struct StopMediaCaptureContext : public ContextBase {
  Napi::Promise::Deferred deferred;
  
  StopMediaCaptureContext(MediaCapture* inst, Napi::Promise::Deferred def) 
    : ContextBase(inst), deferred(std::move(def)) {}
};

// enable_shared_from_thisを削除
class MediaCapture : public Napi::ObjectWrap<MediaCapture> {
 public:
  static Napi::Object Init(Napi::Env env, Napi::Object exports);
  MediaCapture(const Napi::CallbackInfo& info);
  ~MediaCapture();
  
  // 宣言のみに変更（実装はソースファイルで）
  void AbortAllThreadSafeFunctions();
  void RequestStopFromBackgroundThread(StopMediaCaptureContext* context);
  void RequestStopFromBackgroundThread(StopContext* context);
  void ProcessStopMediaCaptureRequest();
  void ProcessStopRequest();

 private:
  static Napi::Value EnumerateTargets(const Napi::CallbackInfo& info);
  Napi::Value StartCapture(const Napi::CallbackInfo& info);
  Napi::Value StopCapture(const Napi::CallbackInfo& info);
  
  void SafeShutdown();

  void* captureHandle_;
  std::atomic<bool> isCapturing_{false};
  Napi::ThreadSafeFunction tsfn_video_;
  Napi::ThreadSafeFunction tsfn_audio_;
  Napi::ThreadSafeFunction tsfn_error_;
  
  static void VideoFrameCallback(uint8_t* data, int32_t width, int32_t height, 
                                int32_t bytesPerRow, int32_t timestamp,
                                const char* format, size_t actualBufferSize, void* ctx);
  
  static void AudioDataCallback(int32_t channels, int32_t sampleRate, 
                             float* buffer, int32_t frameCount, void* ctx);
  
  static void ExitCallback(char* error, void* ctx);
  static void StopCallback(void* ctx);

  std::mutex mutex_;
  std::atomic<bool> stopRequested_{false};
  
  StopContext* pendingStopContext_{nullptr};
  StopMediaCaptureContext* pendingMediaStopContext_{nullptr};
};

#endif // MEDIA_CAPTURE_H