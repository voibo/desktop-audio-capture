#include "mediacapture.h"
#include <iostream>
#include <string>

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
  
  // ネイティブリソースの初期化
  captureHandle_ = createMediaCapture();
}

MediaCapture::~MediaCapture() {
  // まだキャプチャ中なら停止
  if (isCapturing_) {
    stopMediaCapture(captureHandle_, &MediaCapture::StopCallback, nullptr);
  }
  
  // ネイティブリソースの解放
  if (captureHandle_) {
    destroyMediaCapture(captureHandle_);
    captureHandle_ = nullptr;
  }
}

// 静的メソッド - キャプチャターゲットの列挙
Napi::Value MediaCapture::EnumerateTargets(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Promise::Deferred deferred = Napi::Promise::Deferred::New(env);
  
  // ターゲットタイプ (0=all, 1=screen, 2=window)
  int32_t targetType = 0;
  if (info.Length() > 0 && info[0].IsNumber()) {
    targetType = info[0].As<Napi::Number>().Int32Value();
  }
  
  struct EnumerateContext {
    Napi::Promise::Deferred deferred;
    Napi::Env env;
  };
  
  auto context = new EnumerateContext { deferred, env };
  
  // 列挙コールバック
  auto callback = [](MediaCaptureTargetC* targets, int32_t count, char* error, void* ctx) {
    auto context = static_cast<EnumerateContext*>(ctx);
    Napi::Env env = context->env;
    
    if (error) {
      // エラー発生時
      Napi::Error err = Napi::Error::New(env, error);
      context->deferred.Reject(err.Value());
    } else {
      // 成功時 - JavaScript配列に変換
      Napi::Array result = Napi::Array::New(env, count);
      
      for (int i = 0; i < count; i++) {
        Napi::Object target = Napi::Object::New(env);
        target.Set("isDisplay", Napi::Boolean::New(env, targets[i].isDisplay == 1));
        target.Set("isWindow", Napi::Boolean::New(env, targets[i].isWindow == 1));
        target.Set("displayId", Napi::Number::New(env, targets[i].displayID));
        target.Set("windowId", Napi::Number::New(env, targets[i].windowID));
        target.Set("width", Napi::Number::New(env, targets[i].width));
        target.Set("height", Napi::Number::New(env, targets[i].height));
        
        if (targets[i].title) {
          target.Set("title", Napi::String::New(env, targets[i].title));
        }
        
        if (targets[i].appName) {
          target.Set("applicationName", Napi::String::New(env, targets[i].appName));
        }
        
        // フレームオブジェクトの作成
        Napi::Object frame = Napi::Object::New(env);
        frame.Set("width", Napi::Number::New(env, targets[i].width));
        frame.Set("height", Napi::Number::New(env, targets[i].height));
        target.Set("frame", frame);
        
        result[i] = target;
      }
      
      context->deferred.Resolve(result);
    }
    
    delete context;
  };
  
  // ネイティブ関数呼び出し
  enumerateMediaCaptureTargets(targetType, callback, context);
  
  return deferred.Promise();
}

// キャプチャ開始
Napi::Value MediaCapture::StartCapture(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Promise::Deferred deferred = Napi::Promise::Deferred::New(env);
  
  // 既にキャプチャ中ならエラー
  if (isCapturing_) {
    deferred.Reject(Napi::Error::New(env, "Capture already in progress").Value());
    return deferred.Promise();
  }
  
  // 設定オブジェクトのチェック
  if (info.Length() < 1 || !info[0].IsObject()) {
    deferred.Reject(Napi::Error::New(env, "Configuration object required").Value());
    return deferred.Promise();
  }
  
  Napi::Object config = info[0].As<Napi::Object>();
  
  // C構造体の設定
  MediaCaptureConfigC captureConfig = {};
  
  // デフォルト値で初期化
  captureConfig.frameRate = 10.0f;
  captureConfig.quality = 1;
  captureConfig.audioSampleRate = 44100;
  captureConfig.audioChannels = 2;
  
  // JavaScriptオブジェクトから値を取得
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
  
  // ヘッダーで定義したCaptureContextを使用
  auto context = new CaptureContext { this, deferred };
  
  // イベント用スレッドセーフ関数の作成
  this->tsfn_video_ = Napi::ThreadSafeFunction::New(
    env,
    info.This().As<Napi::Object>().Get("emit").As<Napi::Function>(),
    "VideoEmitter",
    0,
    1,
    [this](Napi::Env) {
      // Finalizer
      this->tsfn_video_ = nullptr;
    }
  );
  
  this->tsfn_audio_ = Napi::ThreadSafeFunction::New(
    env,
    info.This().As<Napi::Object>().Get("emit").As<Napi::Function>(),
    "AudioEmitter",
    0,
    1,
    [this](Napi::Env) {
      // Finalizer
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
      // Finalizer
      this->tsfn_error_ = nullptr;
    }
  );
  
  // キャプチャ開始
  isCapturing_ = true;
  
  startMediaCapture(
    captureHandle_, 
    captureConfig, 
    &MediaCapture::VideoFrameCallback,
    &MediaCapture::AudioDataCallback,
    &MediaCapture::ExitCallback,
    context
  );
  
  // 設定でbundleIdが指定されていた場合は解放
  if (captureConfig.bundleID) {
    free(captureConfig.bundleID);
  }
  
  // C++側からはPromiseを即時に解決
  deferred.Resolve(env.Undefined());
  return deferred.Promise();
}

// キャプチャ停止
Napi::Value MediaCapture::StopCapture(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Promise::Deferred deferred = Napi::Promise::Deferred::New(env);
  
  if (!isCapturing_) {
    deferred.Reject(Napi::Error::New(env, "No capture in progress").Value());
    return deferred.Promise();
  }
  
  struct StopContext {
    MediaCapture* instance;
    Napi::Promise::Deferred deferred;
  };
  
  auto context = new StopContext { this, deferred };
  
  // ネイティブ関数でキャプチャ停止
  stopMediaCapture(captureHandle_, [](void* ctx) {
    auto context = static_cast<StopContext*>(ctx);
    MediaCapture* instance = context->instance;
    
    // キャプチャ状態を更新
    instance->isCapturing_ = false;
    
    // Thread-safe function の解放
    if (instance->tsfn_video_) {
      instance->tsfn_video_.Release();
    }
    
    if (instance->tsfn_audio_) {
      instance->tsfn_audio_.Release();
    }
    
    if (instance->tsfn_error_) {
      instance->tsfn_error_.Release();
    }
    
    // Promise解決
    context->deferred.Resolve(context->deferred.Env().Undefined());
    delete context;
  }, context);
  
  return deferred.Promise();
}

// ビデオフレームコールバック
void MediaCapture::VideoFrameCallback(uint8_t* data, int32_t width, int32_t height, 
                                  int32_t bytesPerRow, int32_t timestamp, void* ctx) {
  auto context = static_cast<CaptureContext*>(ctx);
  auto instance = context->instance;
  
  // 終了済みなら何もしない
  if (!instance->isCapturing_ || !instance->tsfn_video_) {
    return;
  }
  
  // バッファサイズの計算
  size_t bufferSize = height * bytesPerRow;
  
  // 新しいバッファにデータをコピー
  uint8_t* videoBuffer = new uint8_t[bufferSize];
  memcpy(videoBuffer, data, bufferSize);
  
  // イベント発行
  instance->tsfn_video_.NonBlockingCall([videoBuffer, width, height, bytesPerRow, timestamp, bufferSize](Napi::Env env, Napi::Function jsCallback) {
    // ビデオデータの作成
    Napi::ArrayBuffer buffer = Napi::ArrayBuffer::New(env, bufferSize);
    uint8_t* bufferData = reinterpret_cast<uint8_t*>(buffer.Data());
    memcpy(bufferData, videoBuffer, bufferSize);
    delete[] videoBuffer; // すぐに削除
    
    Napi::Uint8Array videoData = Napi::Uint8Array::New(env, bufferSize, buffer, 0);
    
    // フレームオブジェクト
    Napi::Object frame = Napi::Object::New(env);
    frame.Set("timestamp", Napi::Number::New(env, timestamp / 1000.0)); // 秒単位に変換
    frame.Set("width", Napi::Number::New(env, width));
    frame.Set("height", Napi::Number::New(env, height));
    frame.Set("bytesPerRow", Napi::Number::New(env, bytesPerRow));
    frame.Set("videoData", videoData);
    
    // イベント発行
    jsCallback.Call({Napi::String::New(env, "video-frame"), frame});
  });
}

// オーディオデータコールバック
void MediaCapture::AudioDataCallback(int32_t channels, int32_t sampleRate, 
                                 float* buffer, int32_t frameCount, void* ctx) {
  auto context = static_cast<CaptureContext*>(ctx);
  auto instance = context->instance;
  
  // 終了済みなら何もしない
  if (!instance->isCapturing_ || !instance->tsfn_audio_) {
    return;
  }
  
  // バッファサイズの計算
  size_t bufferSize = frameCount * channels;
  
  // 新しいバッファにデータをコピー
  float* audioBuffer = new float[bufferSize];
  memcpy(audioBuffer, buffer, bufferSize * sizeof(float));
  
  // イベント発行
  instance->tsfn_audio_.NonBlockingCall([audioBuffer, channels, sampleRate, frameCount, bufferSize](Napi::Env env, Napi::Function jsCallback) {
    // オーディオデータの作成
    Napi::ArrayBuffer buffer = Napi::ArrayBuffer::New(env, bufferSize * sizeof(float));
    float* bufferData = reinterpret_cast<float*>(buffer.Data());
    memcpy(bufferData, audioBuffer, bufferSize * sizeof(float));
    delete[] audioBuffer; // すぐに削除
    
    Napi::Float32Array audioData = Napi::Float32Array::New(env, bufferSize, buffer, 0);
    
    // イベント発行
    jsCallback.Call({
      Napi::String::New(env, "audio-data"), 
      audioData,
      Napi::Number::New(env, sampleRate),
      Napi::Number::New(env, channels)
    });
  });
}

// エラーコールバック
void MediaCapture::ExitCallback(char* error, void* ctx) {
  auto context = static_cast<CaptureContext*>(ctx);
  auto instance = context->instance;
  
  if (error) {
    // エラーがある場合はイベント発行
    if (instance->tsfn_error_) {
      std::string errorMessage(error);
      
      instance->tsfn_error_.NonBlockingCall([errorMessage](Napi::Env env, Napi::Function jsCallback) {
        Napi::Error err = Napi::Error::New(env, errorMessage);
        jsCallback.Call({Napi::String::New(env, "error"), err.Value()});
      });
    }
  }
  
  // キャプチャ状態を更新
  instance->isCapturing_ = false;
  
  // Thread-safe function の解放
  if (instance->tsfn_video_) {
    instance->tsfn_video_.Release();
  }
  
  if (instance->tsfn_audio_) {
    instance->tsfn_audio_.Release();
  }
  
  if (instance->tsfn_error_) {
    instance->tsfn_error_.Release();
  }
  
  // Promiseの解決（初期起動時のみ）
  if (context && !instance->isCapturing_) {
    context->deferred.Resolve(context->deferred.Env().Undefined());
    delete context;
  }
}

// 停止コールバック
void MediaCapture::StopCallback(void* ctx) {
  // これは単純なプレースホルダー
  // 実際の実装はStopCapture内のラムダ関数で行われる
}