#include "mediacapture.h"
#include <iostream>
#include <string>
#include <memory>

Napi::Object MediaCapture::Init(Napi::Env env, Napi::Object exports) {
  Napi::HandleScope scope(env);

  Napi::Function func = DefineClass(env, "MediaCapture", {
    InstanceMethod("startCapture", &MediaCapture::StartCapture),
    InstanceMethod("stopCapture", &MediaCapture::StopCapture),
    StaticMethod("enumerateMediaCaptureTargets", &MediaCapture::EnumerateTargets),
  });

  Napi::FunctionReference* constructor = new Napi::FunctionReference();
  *constructor = Napi::Persistent(func);
  
  env.SetInstanceData(constructor);

  exports.Set("MediaCapture", func);
  return exports;
}

MediaCapture::MediaCapture(const Napi::CallbackInfo& info) 
  : Napi::ObjectWrap<MediaCapture>(info), isCapturing_(false), captureHandle_(nullptr) {
  Napi::Env env = info.Env();
  Napi::HandleScope scope(env);
  
  captureHandle_ = createMediaCapture();
}

void MediaCapture::SafeShutdown() {
  bool was_capturing = isCapturing_.exchange(false);
  if (was_capturing) {
    fprintf(stderr, "DEBUG: Safe shutdown - stopping capture\n");
    
    if (captureHandle_) {
      stopMediaCapture(captureHandle_, nullptr, nullptr);
    }
  }
  
  if (tsfn_video_) {
    fprintf(stderr, "DEBUG: Safe shutdown - aborting video TSF\n");
    tsfn_video_.Abort();
    tsfn_video_ = Napi::ThreadSafeFunction();
  }
  
  if (tsfn_audio_) {
    fprintf(stderr, "DEBUG: Safe shutdown - aborting audio TSF\n");
    tsfn_audio_.Abort();
    tsfn_audio_ = Napi::ThreadSafeFunction();
  }
  
  if (tsfn_error_) {
    fprintf(stderr, "DEBUG: Safe shutdown - aborting error TSF\n");
    tsfn_error_.Abort();
    tsfn_error_ = Napi::ThreadSafeFunction();
  }
  
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
}

MediaCapture::~MediaCapture() {
  SafeShutdown();
  
  if (captureHandle_) {
    destroyMediaCapture(captureHandle_);
    captureHandle_ = nullptr;
  }
}

// EnumerateTargets メソッドを修正
Napi::Value MediaCapture::EnumerateTargets(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Promise::Deferred deferred = Napi::Promise::Deferred::New(env);
  
  int32_t targetType = 0;
  if (info.Length() > 0 && info[0].IsNumber()) {
    targetType = info[0].As<Napi::Number>().Int32Value();
  }
  
  // スレッドセーフコンテキストの作成
  struct EnumerateContext {
    Napi::Promise::Deferred deferred;
    Napi::ThreadSafeFunction tsfn;
    
    ~EnumerateContext() {
      // デストラクタでAbort呼び出しを確保
      if (tsfn) {
        tsfn.Abort();
      }
    }
  };
  
  auto context = new EnumerateContext { 
    deferred,
    // ThreadSafeFunctionを作成し、Node.jsのメインスレッドとの連携を確保
    Napi::ThreadSafeFunction::New(
      env,
      Napi::Function::New(env, [](const Napi::CallbackInfo&){}),
      "EnumerateTargetsCallback",
      0, 
      1,
      [](Napi::Env) {}
    )
  };
  
  // スレッドセーフなコールバック
  auto callback = [](MediaCaptureTargetC* targets, int32_t count, char* error, void* ctx) {
    auto context = static_cast<EnumerateContext*>(ctx);
    
    if (error) {
      // エラー発生時
      std::string errorMessage(error);
      context->tsfn.BlockingCall([errorMessage, context](Napi::Env env, Napi::Function) {
        Napi::HandleScope scope(env);
        Napi::Error err = Napi::Error::New(env, errorMessage);
        context->deferred.Reject(err.Value());
        delete context;
      });
    } else {
      // 成功時
      // ターゲットデータをコピー
      std::vector<MediaCaptureTargetC> targetsCopy;
      for (int i = 0; i < count; i++) {
        MediaCaptureTargetC target = targets[i];
        
        // タイトルと名前の文字列をコピー
        if (target.title) {
          target.title = strdup(target.title);
        }
        if (target.appName) {
          target.appName = strdup(target.appName);
        }
        
        targetsCopy.push_back(target);
      }
      
      context->tsfn.BlockingCall([targetsCopy, context](Napi::Env env, Napi::Function) {
        Napi::HandleScope scope(env);
        
        Napi::Array result = Napi::Array::New(env, targetsCopy.size());
        
        for (size_t i = 0; i < targetsCopy.size(); i++) {
          const auto& target = targetsCopy[i];
          
          Napi::Object obj = Napi::Object::New(env);
          obj.Set("isDisplay", Napi::Boolean::New(env, target.isDisplay == 1));
          obj.Set("isWindow", Napi::Boolean::New(env, target.isWindow == 1));
          obj.Set("displayId", Napi::Number::New(env, target.displayID));
          obj.Set("windowId", Napi::Number::New(env, target.windowID));
          obj.Set("width", Napi::Number::New(env, target.width));
          obj.Set("height", Napi::Number::New(env, target.height));
          
          if (target.title) {
            obj.Set("title", Napi::String::New(env, target.title));
            free(target.title);
          }
          
          if (target.appName) {
            obj.Set("applicationName", Napi::String::New(env, target.appName));
            free(target.appName);
          }
          
          Napi::Object frame = Napi::Object::New(env);
          frame.Set("width", Napi::Number::New(env, target.width));
          frame.Set("height", Napi::Number::New(env, target.height));
          obj.Set("frame", frame);
          
          result[i] = obj;
        }
        
        context->deferred.Resolve(result);
        delete context;
      });
    }
  };
  
  // Swift側のenumerateMediaCaptureTargetsを呼び出す
  enumerateMediaCaptureTargets(targetType, callback, context);
  
  return deferred.Promise();
}

Napi::Value MediaCapture::StartCapture(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Promise::Deferred deferred = Napi::Promise::Deferred::New(env);
  
  if (isCapturing_) {
    deferred.Reject(Napi::Error::New(env, "Capture already in progress").Value());
    return deferred.Promise();
  }
  
  if (info.Length() < 1 || !info[0].IsObject()) {
    deferred.Reject(Napi::Error::New(env, "Configuration object required").Value());
    return deferred.Promise();
  }
  
  Napi::Object config = info[0].As<Napi::Object>();
  
  MediaCaptureConfigC captureConfig = {};
  
  captureConfig.frameRate = 10.0f;
  captureConfig.quality = 1;
  captureConfig.audioSampleRate = 44100;
  captureConfig.audioChannels = 2;
  
  if (config.Has("frameRate") && config.Get("frameRate").IsNumber()) {
    captureConfig.frameRate = config.Get("frameRate").As<Napi::Number>().FloatValue();
  }
  
  if (config.Has("quality") && config.Get("quality").IsNumber()) {
    captureConfig.quality = config.Get("quality").As<Napi::Number>().Int32Value();
  }
  
  if (config.Has("audioSampleRate") && config.Get("audioSampleRate").IsNumber()) {
    captureConfig.audioSampleRate = config.Get("audioSampleRate").As<Napi::Number>().Int32Value();
  }
  
  if (config.Has("audioChannels") && config.Get("audioChannels").IsNumber()) {
    captureConfig.audioChannels = config.Get("audioChannels").As<Napi::Number>().Int32Value();
  }
  
  if (config.Has("displayId") && config.Get("displayId").IsNumber()) {
    captureConfig.displayID = config.Get("displayId").As<Napi::Number>().Uint32Value();
  }
  
  if (config.Has("windowId") && config.Get("windowId").IsNumber()) {
    captureConfig.windowID = config.Get("windowId").As<Napi::Number>().Uint32Value();
  }
  
  if (config.Has("bundleId") && config.Get("bundleId").IsString()) {
    std::string bundleId = config.Get("bundleId").As<Napi::String>().Utf8Value();
    captureConfig.bundleID = strdup(bundleId.c_str());
  }
  
  if (captureConfig.displayID == 0 && captureConfig.windowID == 0 && captureConfig.bundleID == nullptr) {
    deferred.Reject(Napi::Error::New(env, "No valid capture target specified. Please provide displayId, windowId, or bundleId").Value());
    return deferred.Promise();
  }

  auto context = new CaptureContext { this, deferred };
  
  this->tsfn_video_ = Napi::ThreadSafeFunction::New(
    env,
    info.This().As<Napi::Object>().Get("emit").As<Napi::Function>(),
    "VideoFrameCallback",
    8,
    1,
    this,
    [](Napi::Env env, void* finalizeData, MediaCapture* context) {
      fprintf(stderr, "DEBUG: Video TSFN finalized\n");
    },
    context
  );
  
  this->tsfn_audio_ = Napi::ThreadSafeFunction::New(
    env,
    info.This().As<Napi::Object>().Get("emit").As<Napi::Function>(),
    "AudioEmitter",
    0,
    1,
    [this](Napi::Env) {
      this->tsfn_audio_ = nullptr;
    }
  );
  
  this->tsfn_error_ = Napi::ThreadSafeFunction::New(
    env,
    info.This().As<Napi::Object>().Get("emit").As<Napi::Function>(),
    "ErrorEmitter",
    0,
    1,
    [this](Napi::Env) {
      this->tsfn_error_ = nullptr;
    }
  );
  
  isCapturing_ = true;
  
  startMediaCapture(
    captureHandle_, 
    captureConfig, 
    &MediaCapture::VideoFrameCallback,
    &MediaCapture::AudioDataCallback,
    &MediaCapture::ExitCallback,
    context
  );
  
  if (captureConfig.bundleID) {
    free(captureConfig.bundleID);
  }
  
  deferred.Resolve(env.Undefined());
  return deferred.Promise();
}

static void StopMediaCaptureTrampoline(void* ctx) {
  auto context = static_cast<StopMediaCaptureContext*>(ctx);
  if (!context) return;
  
  auto instance = context->instance;
  
  if (instance) {
      instance->RequestStopFromBackgroundThread(context);
  } else {
      delete context;
  }
}

Napi::Value MediaCapture::StopCapture(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    Napi::HandleScope scope(env);
    
    Napi::Promise::Deferred deferred = Napi::Promise::Deferred::New(env);
    
    if (!isCapturing_.load()) {
        deferred.Resolve(env.Undefined());
        return deferred.Promise();
    }
    
    isCapturing_.store(false);
    
    auto context = new StopMediaCaptureContext(this, deferred);
    
    stopMediaCapture(captureHandle_, StopMediaCaptureTrampoline, context);
    
    return deferred.Promise();
}

void MediaCapture::VideoFrameCallback(uint8_t* data, int32_t width, int32_t height, 
                                  int32_t bytesPerRow, int32_t timestamp,
                                  const char* format, size_t actualBufferSize, void* ctx) {
    if (!ctx || !data) return;
    auto context = static_cast<CaptureContext*>(ctx);
    auto instance = context->instance;
    
    bool is_capturing = instance && instance->isCapturing_.load();
    if (!is_capturing) {
        fputs("DEBUG: Ignoring video frame - capture is inactive\n", stderr);
        return;
    }
    
    auto tsfn = instance->tsfn_video_;
    if (!tsfn) {
        fputs("DEBUG: Video TSFN is not available\n", stderr);
        return;
    }
    
    napi_status status = tsfn.Acquire();
    if (status != napi_ok) {
        fputs("DEBUG: Failed to acquire TSFN\n", stderr);
        return;
    }
    
    const bool isJpeg = (format && strcmp(format, "jpeg") == 0);
    
    std::shared_ptr<uint8_t[]> dataCopy;
    size_t dataSize = 0;
    
    if (isJpeg) {
        dataSize = actualBufferSize;
        dataCopy = std::shared_ptr<uint8_t[]>(new (std::nothrow) uint8_t[dataSize]);
        if (!dataCopy) {
            fprintf(stderr, "ERROR: Failed to allocate JPEG buffer\n");
            return;
        }
        memcpy(dataCopy.get(), data, dataSize);
    } else {
        dataSize = static_cast<size_t>(height) * static_cast<size_t>(bytesPerRow);
        dataCopy = std::shared_ptr<uint8_t[]>(new (std::nothrow) uint8_t[dataSize]);
        if (!dataCopy) {
            fprintf(stderr, "ERROR: Failed to allocate buffer\n");
            return;
        }
        
        const size_t rowBytes = std::min(static_cast<size_t>(bytesPerRow), 
                                      actualBufferSize / static_cast<size_t>(height));
        
        for (int32_t y = 0; y < height; y++) {
            const size_t srcOffset = y * bytesPerRow;
            const size_t destOffset = y * bytesPerRow;
            
            if (srcOffset + rowBytes > actualBufferSize || destOffset + rowBytes > dataSize) break;
            memcpy(dataCopy.get() + destOffset, data + srcOffset, rowBytes);
        }
    }
    
    auto dataCopy_shared = dataCopy;
    
    is_capturing = instance->isCapturing_.load();
    if (!is_capturing) {
        fputs("DEBUG: Skipping video callback - capture was stopped\n", stderr);
        return;
    }
    
    tsfn.NonBlockingCall([dataCopy_shared, width, height, bytesPerRow, timestamp, dataSize, isJpeg]
                    (Napi::Env env, Napi::Function jsCallback) {
        Napi::HandleScope scope(env);
        
        try {
            Napi::ArrayBuffer buffer = Napi::ArrayBuffer::New(env, dataSize);
            memcpy(buffer.Data(), dataCopy_shared.get(), dataSize);
            
            Napi::Object frame = Napi::Object::New(env);
            frame.Set("width", Napi::Number::New(env, width));
            frame.Set("height", Napi::Number::New(env, height));
            frame.Set("bytesPerRow", Napi::Number::New(env, bytesPerRow));
            frame.Set("timestamp", Napi::Number::New(env, timestamp / 1000.0));
            frame.Set("isJpeg", Napi::Boolean::New(env, isJpeg));
            
            frame.Set("data", Napi::Uint8Array::New(env, dataSize, buffer, 0));
            
            if (jsCallback.IsFunction()) {
                try {
                    jsCallback.Call({
                        Napi::String::New(env, "video-frame"), 
                        frame
                    });
                } catch (const std::exception& e) {
                    fprintf(stderr, "ERROR: JS callback exception: %s\n", e.what());
                }
            } else {
                fprintf(stderr, "ERROR: Invalid JS callback function\n");
            }
        } catch (...) {
            fprintf(stderr, "ERROR: Exception in video frame processing\n");
        }
    });
    
    tsfn.Release();
}

void MediaCapture::AudioDataCallback(int32_t channels, int32_t sampleRate, 
                                 float* buffer, int32_t frameCount, void* ctx) {
  if (!ctx) return;
  auto context = static_cast<CaptureContext*>(ctx);
  auto instance = context->instance;
  if (!instance) return;
  
  bool is_capturing = instance->isCapturing_;
  if (!is_capturing) return;

  auto tsfn = instance->tsfn_audio_;
  if (!tsfn) return;
  
  if (channels <= 0 || sampleRate <= 0 || frameCount <= 0 || !buffer) {
    fprintf(stderr, "ERROR: Invalid audio parameters\n");
    return;
  }
  
  size_t numSamples = static_cast<size_t>(channels) * static_cast<size_t>(frameCount);
  if (numSamples == 0 || numSamples > 1024 * 1024) {
    fprintf(stderr, "ERROR: Invalid audio buffer size\n");
    return;
  }
  
  auto audioCopy = std::make_unique<float[]>(numSamples);
  if (!audioCopy) {
    fprintf(stderr, "ERROR: Failed to allocate audio buffer\n");
    return;
  }
  
  std::memcpy(audioCopy.get(), buffer, numSamples * sizeof(float));
  
  int32_t channelsCopy = channels;
  int32_t sampleRateCopy = sampleRate;
  int32_t frameCountCopy = frameCount;
  size_t numSamplesCopy = numSamples;
  
  float* rawAudioPtr = audioCopy.release();
  
  auto tsfn_copy = tsfn;
  tsfn_copy.NonBlockingCall(
    [rawAudioPtr, channelsCopy, sampleRateCopy, frameCountCopy, numSamplesCopy]
    (Napi::Env env, Napi::Function jsCallback) {
      Napi::HandleScope scope(env);
      
      try {
        Napi::ArrayBuffer buffer = Napi::ArrayBuffer::New(env, numSamplesCopy * sizeof(float));
        if (buffer.ByteLength() != numSamplesCopy * sizeof(float)) {
          fprintf(stderr, "ERROR: ArrayBuffer allocation failed\n");
          delete[] rawAudioPtr;
          return;
        }
        
        std::memcpy(buffer.Data(), rawAudioPtr, numSamplesCopy * sizeof(float));
        
        delete[] rawAudioPtr;
        
        Napi::Float32Array audioData = Napi::Float32Array::New(env, numSamplesCopy, buffer, 0);
        
        try {
          if (jsCallback.IsFunction()) {
            jsCallback.Call({
              Napi::String::New(env, "audio-data"), 
              audioData,
              Napi::Number::New(env, sampleRateCopy),
              Napi::Number::New(env, channelsCopy)
            });
          }
        } catch (const std::exception& e) {
          fprintf(stderr, "ERROR: Exception during JS callback: %s\n", e.what());
        } catch (...) {
          fprintf(stderr, "ERROR: Unknown exception during JS callback\n");
        }
      }
      catch (...) {
        delete[] rawAudioPtr;
      }
    });
}

void MediaCapture::ExitCallback(char* error, void* ctx) {
  if (!ctx) {
    fprintf(stderr, "ERROR: ExitCallback received null context\n");
    return;
  }
  
  auto context = static_cast<CaptureContext*>(ctx);
  auto instance = context->instance;
  
  if (!instance) {
    fprintf(stderr, "ERROR: ExitCallback received null instance\n");
    delete context;
    return;
  }
  
  bool was_capturing = instance->isCapturing_.exchange(false);
  
  auto tsfn_error = instance->tsfn_error_;
  
  if (error) {
    fprintf(stderr, "DEBUG: Capture exited with error: %s\n", error);
    
    if (tsfn_error) {
      std::string errorMessage(error);
      
      tsfn_error.NonBlockingCall([errorMessage](Napi::Env env, Napi::Function jsCallback) {
        try {
          if (jsCallback.IsFunction()) {
            Napi::HandleScope scope(env);
            Napi::Error err = Napi::Error::New(env, errorMessage);
            jsCallback.Call({Napi::String::New(env, "error"), err.Value()});
          }
        } catch (const std::exception& e) {
          fprintf(stderr, "ERROR: Exception in error callback: %s\n", e.what());
        }
      });
    }
  }
  
  Napi::Promise::Deferred deferred = context->deferred;
  Napi::Env env = deferred.Env();
  
  Napi::ThreadSafeFunction resolverTsfn = Napi::ThreadSafeFunction::New(
    env,
    Napi::Function::New(env, [](const Napi::CallbackInfo&){}),
    Napi::Object::New(env),
    "ExitResolver",
    0,
    1
  );
  
  if (error) {
    std::string errorCopy(error);
    resolverTsfn.BlockingCall([deferred, errorCopy](Napi::Env env, Napi::Function) {
      Napi::HandleScope scope(env);
      Napi::Error err = Napi::Error::New(env, errorCopy);
      deferred.Reject(err.Value());
    });
  } else {
    resolverTsfn.BlockingCall([deferred](Napi::Env env, Napi::Function) {
      Napi::HandleScope scope(env);
      deferred.Resolve(env.Undefined());
    });
  }
  
  resolverTsfn.Release();
  
  instance->SafeShutdown();
  
  delete context;
}

void MediaCapture::StopCallback(void* ctx) {
  if (!ctx) return;
  
  auto context = static_cast<StopContext*>(ctx);
  MediaCapture* instance = context->instance;
  
  if (!instance) {
    delete context;
    return;
  }
  
  instance->isCapturing_ = false;
  
  Napi::Promise::Deferred deferred = context->deferred;
  Napi::ThreadSafeFunction resolverTsfn = Napi::ThreadSafeFunction::New(
    deferred.Env(),
    Napi::Function::New(deferred.Env(), [](const Napi::CallbackInfo&) {}),
    Napi::Object::New(deferred.Env()),
    "StopResolver",
    0,
    1
  );
  
  resolverTsfn.BlockingCall([deferred](Napi::Env env, Napi::Function) {
    Napi::HandleScope scope(env);
    deferred.Resolve(env.Undefined());
  });
  
  resolverTsfn.Release();
  
  if (instance->tsfn_video_) {
    instance->tsfn_video_.Abort();
    instance->tsfn_video_ = Napi::ThreadSafeFunction();
  }
  
  if (instance->tsfn_audio_) {
    instance->tsfn_audio_.Abort();
    instance->tsfn_audio_ = Napi::ThreadSafeFunction();
  }
  
  if (instance->tsfn_error_) {
    instance->tsfn_error_.Abort();
    instance->tsfn_error_ = Napi::ThreadSafeFunction();
  }
  
  delete context;
}