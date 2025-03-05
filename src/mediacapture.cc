#include "mediacapture.h"
#include <iostream>
#include <string>
#include <memory>  // std::shared_ptrのために追加

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
  
  // Initialize native resource
  captureHandle_ = createMediaCapture();
}

// クラスに安全なシャットダウンメソッドを追加
void MediaCapture::SafeShutdown() {
  // キャプチャが実行中の場合は停止
  bool was_capturing = isCapturing_.exchange(false);
  if (was_capturing) {
    fprintf(stderr, "DEBUG: Safe shutdown - stopping capture\n");
    
    // ネイティブキャプチャの停止
    if (captureHandle_) {
      stopMediaCapture(captureHandle_, nullptr, nullptr);
    }
  }
  
  // ThreadSafeFunctionのクリーンアップ
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
  
  // 少し待機してスレッドが終了する時間を与える
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
}

// デストラクタを修正
MediaCapture::~MediaCapture() {
  // 安全に終了
  SafeShutdown();
  
  // ネイティブリソース解放
  if (captureHandle_) {
    destroyMediaCapture(captureHandle_);
    captureHandle_ = nullptr;
  }
}

// Static method - Enumerate capture targets
Napi::Value MediaCapture::EnumerateTargets(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Promise::Deferred deferred = Napi::Promise::Deferred::New(env);
  
  // Target type (0=all, 1=screen, 2=window)
  int32_t targetType = 0;
  if (info.Length() > 0 && info[0].IsNumber()) {
    targetType = info[0].As<Napi::Number>().Int32Value();
  }
  
  struct EnumerateContext {
    Napi::Promise::Deferred deferred;
    Napi::Env env;
  };
  
  auto context = new EnumerateContext { deferred, env };
  
  // Enumeration callback
  auto callback = [](MediaCaptureTargetC* targets, int32_t count, char* error, void* ctx) {
    auto context = static_cast<EnumerateContext*>(ctx);
    Napi::Env env = context->env;
    
    if (error) {
      // Error handling
      Napi::Error err = Napi::Error::New(env, error);
      context->deferred.Reject(err.Value());
    } else {
      // Success - convert to JavaScript array
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
        
        // Create frame object
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
  
  // Call native function
  enumerateMediaCaptureTargets(targetType, callback, context);
  
  return deferred.Promise();
}

// Start capture - Standard version
Napi::Value MediaCapture::StartCapture(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  Napi::Promise::Deferred deferred = Napi::Promise::Deferred::New(env);
  
  // Check if already capturing
  if (isCapturing_) {
    deferred.Reject(Napi::Error::New(env, "Capture already in progress").Value());
    return deferred.Promise();
  }
  
  // Check configuration object
  if (info.Length() < 1 || !info[0].IsObject()) {
    deferred.Reject(Napi::Error::New(env, "Configuration object required").Value());
    return deferred.Promise();
  }
  
  Napi::Object config = info[0].As<Napi::Object>();
  
  // Configure C struct
  MediaCaptureConfigC captureConfig = {};
  
  // Initialize with defaults
  captureConfig.frameRate = 10.0f;
  captureConfig.quality = 1;
  captureConfig.audioSampleRate = 44100;
  captureConfig.audioChannels = 2;
  
  // Get values from JavaScript object
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
  
  // Check existence of target
  if (captureConfig.displayID == 0 && captureConfig.windowID == 0 && captureConfig.bundleID == nullptr) {
    deferred.Reject(Napi::Error::New(env, "No valid capture target specified. Please provide displayId, windowId, or bundleId").Value());
    return deferred.Promise();
  }

  // Use capture context defined in header
  auto context = new CaptureContext { this, deferred };
  
  // Create thread-safe functions for events
  this->tsfn_video_ = Napi::ThreadSafeFunction::New(
    env,
    info.This().As<Napi::Object>().Get("emit").As<Napi::Function>(),
    "VideoFrameCallback",
    8,       // Max queue size
    1,       // Initial thread count
    this,    // Finalizer data
    [](Napi::Env env, void* finalizeData, MediaCapture* context) {
      // Finalizer - nothing to do
      fprintf(stderr, "DEBUG: Video TSFN finalized\n");
    },
    context  // Context data
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
  
  // Start capture
  isCapturing_ = true;
  
  startMediaCapture(
    captureHandle_, 
    captureConfig, 
    &MediaCapture::VideoFrameCallback,
    &MediaCapture::AudioDataCallback,
    &MediaCapture::ExitCallback,
    context
  );
  
  // Free bundleId if it was specified
  if (captureConfig.bundleID) {
    free(captureConfig.bundleID);
  }
  
  // Resolve promise immediately from C++ side
  deferred.Resolve(env.Undefined());
  return deferred.Promise();
}

// 静的なトランポリン関数 - C APIが期待する形式に合致
// 修正版: SwiftからのコールバックでV8オブジェクトを直接操作しない
static void StopMediaCaptureTrampoline(void* ctx) {
  auto context = static_cast<StopMediaCaptureContext*>(ctx);
  if (!context) return;
  
  auto instance = context->instance;
  
  // ここではV8オブジェクト作成やPromise操作を行わない
  // 単に停止フラグを設定するだけにする
  if (instance) {
      // Swiftスレッドからメインスレッドに通知
      instance->RequestStopFromBackgroundThread(context);
  } else {
      // インスタンスがない場合はコンテキストを解放
      delete context;
  }
}

// StopCaptureメソッドの修正
Napi::Value MediaCapture::StopCapture(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    Napi::HandleScope scope(env);
    
    Napi::Promise::Deferred deferred = Napi::Promise::Deferred::New(env);
    
    if (!isCapturing_.load()) {
        deferred.Resolve(env.Undefined());
        return deferred.Promise();
    }
    
    // 状態を更新
    isCapturing_.store(false);
    
    // 通常のコンストラクタ構文に変更し、引数の順序を修正
    auto context = new StopMediaCaptureContext(this, deferred);
    
    // C関数ポインタとコンテキストを使用
    stopMediaCapture(captureHandle_, StopMediaCaptureTrampoline, context);
    
    return deferred.Promise();
}

// VideoFrameCallback修正 - スレッドセーフなコールバック制御
void MediaCapture::VideoFrameCallback(uint8_t* data, int32_t width, int32_t height, 
                                  int32_t bytesPerRow, int32_t timestamp,
                                  const char* format, size_t actualBufferSize, void* ctx) {
    // 基本検証
    if (!ctx || !data) return;
    auto context = static_cast<CaptureContext*>(ctx);
    auto instance = context->instance;
    
    // キャプチャ中かどうかのアトミックな確認
    bool is_capturing = instance && instance->isCapturing_.load();
    if (!is_capturing) {
        fputs("DEBUG: Ignoring video frame - capture is inactive\n", stderr);
        return;
    }
    
    // TSFN有効性確認
    auto tsfn = instance->tsfn_video_;
    if (!tsfn) {
        fputs("DEBUG: Video TSFN is not available\n", stderr);
        return;
    }
    
    // TSFNのAcquire/Releaseペアで安全に使用
    napi_status status = tsfn.Acquire();
    if (status != napi_ok) {
        fputs("DEBUG: Failed to acquire TSFN\n", stderr);
        return;
    }
    
    // フォーマットチェック
    const bool isJpeg = (format && strcmp(format, "jpeg") == 0);
    
    // スマートポインタを使用して安全にデータをコピー
    std::shared_ptr<uint8_t[]> dataCopy;
    size_t dataSize = 0;
    
    if (isJpeg) {
        // JPEGデータをコピー
        dataSize = actualBufferSize;
        dataCopy = std::shared_ptr<uint8_t[]>(new (std::nothrow) uint8_t[dataSize]);
        if (!dataCopy) {
            fprintf(stderr, "ERROR: Failed to allocate JPEG buffer\n");
            return;
        }
        memcpy(dataCopy.get(), data, dataSize);
    } else {
        // RAW画像のコピー
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
    
    // 共有ポインタをコピーして使用
    auto dataCopy_shared = dataCopy;
    
    // 最後にキャプチャ状態を再確認してコールバック発行
    is_capturing = instance->isCapturing_.load();
    if (!is_capturing) {
        fputs("DEBUG: Skipping video callback - capture was stopped\n", stderr);
        return;
    }
    
    // コールバックをキューに入れる
    tsfn.NonBlockingCall([dataCopy_shared, width, height, bytesPerRow, timestamp, dataSize, isJpeg]
                    (Napi::Env env, Napi::Function jsCallback) {
        // スコープ作成
        Napi::HandleScope scope(env);
        
        try {
            // バッファを生成
            Napi::ArrayBuffer buffer = Napi::ArrayBuffer::New(env, dataSize);
            memcpy(buffer.Data(), dataCopy_shared.get(), dataSize);
            
            // フレームオブジェクト作成
            Napi::Object frame = Napi::Object::New(env);
            frame.Set("width", Napi::Number::New(env, width));
            frame.Set("height", Napi::Number::New(env, height));
            frame.Set("bytesPerRow", Napi::Number::New(env, bytesPerRow));
            frame.Set("timestamp", Napi::Number::New(env, timestamp / 1000.0));
            frame.Set("isJpeg", Napi::Boolean::New(env, isJpeg));
            
            // データをセット
            frame.Set("data", Napi::Uint8Array::New(env, dataSize, buffer, 0));
            
            // エラーハンドリング強化 - コールバックが関数かどうか検証
            if (jsCallback.IsFunction()) {
                // イベント名を文字列としてセット
                Napi::String eventName = Napi::String::New(env, "video-frame");
                
                // 安全なemit呼び出し
                try {
                    jsCallback.Call({eventName, frame});
                } catch (const std::exception& e) {
                    fprintf(stderr, "ERROR: JS callback exception: %s\n", e.what());
                }
            }
        } catch (...) {
            fprintf(stderr, "ERROR: Exception in video frame processing\n");
        }
    });
    
    // 最後に必ずRelease
    tsfn.Release();
}

// AudioDataCallbackの修正 - 安全なクロージャー実装
void MediaCapture::AudioDataCallback(int32_t channels, int32_t sampleRate, 
                                 float* buffer, int32_t frameCount, void* ctx) {
  // 基本検証
  if (!ctx) return;
  auto context = static_cast<CaptureContext*>(ctx);
  auto instance = context->instance;
  if (!instance) return;
  
  // キャプチャ中でなければ処理しない
  bool is_capturing = instance->isCapturing_;
  if (!is_capturing) return;

  // スレッドセーフ関数が有効か確認
  auto tsfn = instance->tsfn_audio_;
  if (!tsfn) return;
  
  // データサイズの検証
  if (channels <= 0 || sampleRate <= 0 || frameCount <= 0 || !buffer) {
    fprintf(stderr, "ERROR: Invalid audio parameters\n");
    return;
  }
  
  size_t numSamples = static_cast<size_t>(channels) * static_cast<size_t>(frameCount);
  if (numSamples == 0 || numSamples > 1024 * 1024) {
    fprintf(stderr, "ERROR: Invalid audio buffer size\n");
    return;
  }
  
  // データコピー - スマートポインタで安全に
  // ここが二重解放の原因だった可能性が高い
  auto audioCopy = std::make_unique<float[]>(numSamples);
  if (!audioCopy) {
    fprintf(stderr, "ERROR: Failed to allocate audio buffer\n");
    return;
  }
  
  // データをコピー
  std::memcpy(audioCopy.get(), buffer, numSamples * sizeof(float));
  
  // コピーを保持
  int32_t channelsCopy = channels;
  int32_t sampleRateCopy = sampleRate;
  int32_t frameCountCopy = frameCount;
  size_t numSamplesCopy = numSamples;
  
  // ポインタを解放してから別の変数に移動
  float* rawAudioPtr = audioCopy.release();
  
  // コールバックキューに入れる - ローカル変数を強化
  auto tsfn_copy = tsfn; // 念のためローカルにコピー
  tsfn_copy.NonBlockingCall(
    [rawAudioPtr, channelsCopy, sampleRateCopy, frameCountCopy, numSamplesCopy]
    (Napi::Env env, Napi::Function jsCallback) {
      // スコープを確保
      Napi::HandleScope scope(env);
      
      try {
        // ArrayBufferを作成
        Napi::ArrayBuffer buffer = Napi::ArrayBuffer::New(env, numSamplesCopy * sizeof(float));
        if (buffer.ByteLength() != numSamplesCopy * sizeof(float)) {
          fprintf(stderr, "ERROR: ArrayBuffer allocation failed\n");
          delete[] rawAudioPtr;
          return;
        }
        
        // データコピー
        std::memcpy(buffer.Data(), rawAudioPtr, numSamplesCopy * sizeof(float));
        
        // データを解放 - ここで一度だけ解放する
        delete[] rawAudioPtr;
        
        // Float32Array作成
        Napi::Float32Array audioData = Napi::Float32Array::New(env, numSamplesCopy, buffer, 0);
        
        // イベント発火 - エラーハンドリング追加
        try {
          // イベント発火前にコールバックの有効性を確認
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
        // エラー時もデータを必ず解放
        delete[] rawAudioPtr;
      }
    });
}

// Error callback
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
  
  // キャプチャの状態を更新（重複処理防止）
  bool was_capturing = instance->isCapturing_.exchange(false);
  
  // ThreadSafeFunctionのポインタをローカルに保存
  auto tsfn_error = instance->tsfn_error_;
  
  if (error) {
    fprintf(stderr, "DEBUG: Capture exited with error: %s\n", error);
    
    // 有効なエラーTSFNがあれば使用
    if (tsfn_error) {
      std::string errorMessage(error);
      
      // 一回だけ実行するNonBlockingCallに変更
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
  
  // コンテキストのpromiseを解決（TSFNを使わずに別の方法で実行）
  Napi::Promise::Deferred deferred = context->deferred;
  Napi::Env env = deferred.Env();
  
  // 新しいTSFNを作成して安全に解決
  Napi::ThreadSafeFunction resolverTsfn = Napi::ThreadSafeFunction::New(
    env,
    Napi::Function::New(env, [](const Napi::CallbackInfo&){}),
    Napi::Object::New(env),  // resource オブジェクト
    "ExitResolver",
    0,
    1
  );
  
  // エラーがあればreject、なければresolve
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
  
  // 必ずリリース
  resolverTsfn.Release();
  
  // インスタンスのTSFNは別に処理
  instance->SafeShutdown();
  
  // コンテキスト解放
  delete context;
}

// stopMediaCaptureコールバックの修正
void MediaCapture::StopCallback(void* ctx) {
  if (!ctx) return;
  
  // StopContextを取得
  auto context = static_cast<StopContext*>(ctx);
  MediaCapture* instance = context->instance;
  
  if (!instance) {
    delete context;
    return;
  }
  
  // キャプチャ状態を更新 - 先にフラグを変更してコールバック呼び出しを停止
  instance->isCapturing_ = false;
  
  // 別のスレッドからメインスレッドにプロミス解決処理を委任
  Napi::Promise::Deferred deferred = context->deferred;
  Napi::ThreadSafeFunction resolverTsfn = Napi::ThreadSafeFunction::New(
    deferred.Env(),
    Napi::Function::New(deferred.Env(), [](const Napi::CallbackInfo&) {}),
    Napi::Object::New(deferred.Env()),  // resource オブジェクトを追加
    "StopResolver",          // リソース名
    0,                       // キューサイズ
    1                        // 初期スレッド数
  );
  
  // すぐにBlocking Callで解決（非同期ではなく）
  resolverTsfn.BlockingCall([deferred](Napi::Env env, Napi::Function) {
    // このコールバックはメインスレッドで実行され、HandleScopeが存在する
    Napi::HandleScope scope(env);
    deferred.Resolve(env.Undefined());
  });
  
  // クリーンアップ処理
  resolverTsfn.Release();
  
  // TSFNをリリース（このタイミングでなく、プロミス解決の後）
  if (instance->tsfn_video_) {
    instance->tsfn_video_.Abort();  // 強制中断でキューをクリア
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
  
  // コンテキスト解放
  delete context;
}