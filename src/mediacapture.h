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

struct ContextBase {
  class MediaCapture* instance;

  ContextBase(class MediaCapture* inst) : instance(inst) {}
  virtual ~ContextBase() = default;
};

struct CaptureContext : public ContextBase {
  Napi::Promise::Deferred deferred;
  
  CaptureContext(class MediaCapture* inst, Napi::Promise::Deferred def) 
    : ContextBase(inst), deferred(std::move(def)) {}
};

struct StopContext : public ContextBase {
  Napi::Promise::Deferred deferred;
  
  StopContext(class MediaCapture* inst, Napi::Promise::Deferred def) 
    : ContextBase(inst), deferred(std::move(def)) {}
};

struct StopMediaCaptureContext : public ContextBase {
  Napi::Promise::Deferred deferred;
  
  StopMediaCaptureContext(class MediaCapture* inst, Napi::Promise::Deferred def) 
    : ContextBase(inst), deferred(std::move(def)) {}
};

class MediaCapture : public Napi::ObjectWrap<MediaCapture> {
 public:
  static Napi::Object Init(Napi::Env env, Napi::Object exports);
  MediaCapture(const Napi::CallbackInfo& info);
  ~MediaCapture();

  void AbortAllThreadSafeFunctions() {
    if (tsfn_video_) {
      tsfn_video_.Abort();
      tsfn_video_ = Napi::ThreadSafeFunction();
    }
    if (tsfn_audio_) {
      tsfn_audio_.Abort();
      tsfn_audio_ = Napi::ThreadSafeFunction();
    }
    if (tsfn_error_) {
      tsfn_error_.Abort();
      tsfn_error_ = Napi::ThreadSafeFunction();
    }
  }

  void RequestStopFromBackgroundThread(StopMediaCaptureContext* context) {
    std::lock_guard<std::mutex> lock(mutex_);
    stopRequested_ = true;
    isCapturing_ = false;
    
    if (!pendingMediaStopContext_) {
        pendingMediaStopContext_ = context;
        
        if (tsfn_error_) {
            tsfn_error_.NonBlockingCall([this](Napi::Env env, Napi::Function jsCallback) {
                this->ProcessStopMediaCaptureRequest();
            });
        } else {
            delete context;
        }
    } else {
        delete context;
    }
  }
  
  void ProcessStopMediaCaptureRequest() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!pendingMediaStopContext_) return;
    
    auto context = pendingMediaStopContext_;
    pendingMediaStopContext_ = nullptr;
    
    Napi::HandleScope scope(context->deferred.Env());
    
    this->AbortAllThreadSafeFunctions();
    context->deferred.Resolve(context->deferred.Env().Undefined());
    
    delete context;
  }

  void RequestStopFromBackgroundThread(StopContext* context) {
    std::lock_guard<std::mutex> lock(mutex_);
    stopRequested_ = true;
    isCapturing_ = false;

    if (!pendingStopContext_) {
        pendingStopContext_ = context;
        if (tsfn_error_) {
            tsfn_error_.NonBlockingCall([this](Napi::Env env, Napi::Function jsCallback) {
                this->ProcessStopRequest();
            });
        } else {
            delete context;
        }
    } else {
        delete context;
    }
  }
  
  void ProcessStopRequest() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!pendingStopContext_) return;
    
    auto context = pendingStopContext_;
    pendingStopContext_ = nullptr;
    
    Napi::HandleScope scope(context->deferred.Env());
    
    this->AbortAllThreadSafeFunctions();
    context->deferred.Resolve(context->deferred.Env().Undefined());
    
    delete context;
  }

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