#include "mediacapture.h"
#include <iostream>
#include <memory>
#include <string>

Napi::Object MediaCapture::Init(Napi::Env env, Napi::Object exports) {
  Napi::HandleScope scope(env);

  Napi::Function func = DefineClass(
      env, "MediaCapture",
      {
          InstanceMethod("startCapture", &MediaCapture::StartCapture),
          InstanceMethod("stopCapture", &MediaCapture::StopCapture),
          StaticMethod("enumerateMediaCaptureTargets", &MediaCapture::EnumerateTargets),
      });

  Napi::FunctionReference *constructor = new Napi::FunctionReference();
  *constructor                         = Napi::Persistent(func);

  env.SetInstanceData(constructor);

  exports.Set("MediaCapture", func);
  return exports;
}

MediaCapture::MediaCapture(const Napi::CallbackInfo &info) :
    Napi::ObjectWrap<MediaCapture>(info),
    isCapturing_(false),
    captureHandle_(nullptr) {
  Napi::Env         env = info.Env();
  Napi::HandleScope scope(env);

  captureHandle_ = createMediaCapture();
}

void MediaCapture::SafeShutdown() {
  bool was_capturing = isCapturing_.exchange(false);
  if (was_capturing) {
    fprintf(stderr, "DEBUG: Safe shutdown - stopping capture\n");

    if (captureHandle_) {
      try {
        stopMediaCapture(captureHandle_, nullptr, nullptr);
      } catch (const std::exception &e) {
        fprintf(stderr, "ERROR: Exception in stopMediaCapture: %s\n", e.what());
      } catch (...) {
        fprintf(stderr, "ERROR: Unknown exception in stopMediaCapture\n");
      }
    }
  }

  try {
    this->AbortAllThreadSafeFunctions();
  } catch (const std::exception &e) {
    fprintf(stderr, "ERROR: Exception in AbortAllThreadSafeFunctions: %s\n", e.what());
  } catch (...) {
    fprintf(stderr, "ERROR: Unknown exception in AbortAllThreadSafeFunctions\n");
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

Napi::Value MediaCapture::EnumerateTargets(const Napi::CallbackInfo &info) {
  Napi::Env               env      = info.Env();
  Napi::Promise::Deferred deferred = Napi::Promise::Deferred::New(env);

  int32_t targetType = 0;
  if (info.Length() > 0 && info[0].IsNumber()) {
    targetType = info[0].As<Napi::Number>().Int32Value();
  }

  // Create thread-safe context
  struct EnumerateContext {
    Napi::Promise::Deferred  deferred;
    Napi::ThreadSafeFunction tsfn;

    ~EnumerateContext() {
      // Ensure Abort is called in destructor
      if (tsfn) {
        tsfn.Abort();
      }
    }
  };

  auto context = new EnumerateContext{
      deferred,
      // Create ThreadSafeFunction to coordinate with Node.js main thread
      Napi::ThreadSafeFunction::New(
          env, Napi::Function::New(env, [](const Napi::CallbackInfo &) {}), "EnumerateTargetsCallback", 0, 1,
          [](Napi::Env) {})};

  // Thread-safe callback
  auto callback = [](MediaCaptureTargetC *targets, int32_t count, char *error, void *ctx) {
    auto context = static_cast<EnumerateContext *>(ctx);

    if (error) {
      // Handle error
      std::string errorMessage(error);
      context->tsfn.BlockingCall([errorMessage, context](Napi::Env env, Napi::Function) {
        Napi::HandleScope scope(env);
        Napi::Error       err = Napi::Error::New(env, errorMessage);
        context->deferred.Reject(err.Value());
        delete context;
      });
    } else {
      // Success - copy target data
      std::vector<MediaCaptureTargetC> targetsCopy;
      for (int i = 0; i < count; i++) {
        MediaCaptureTargetC target = targets[i];

        // Copy string title and name
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
          const auto &target = targetsCopy[i];

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

  // Call native enumerate function
  enumerateMediaCaptureTargets(targetType, callback, context);

  return deferred.Promise();
}

Napi::Value MediaCapture::StartCapture(const Napi::CallbackInfo &info) {
  Napi::Env               env      = info.Env();
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

  // Default configuration
  captureConfig.frameRate       = 10.0f;
  captureConfig.quality         = 1;
  captureConfig.audioSampleRate = 44100;
  captureConfig.audioChannels   = 2;

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
    std::string bundleId   = config.Get("bundleId").As<Napi::String>().Utf8Value();
    captureConfig.bundleID = strdup(bundleId.c_str());
  }

  if (captureConfig.displayID == 0 && captureConfig.windowID == 0 && captureConfig.bundleID == nullptr) {
    deferred.Reject(
        Napi::Error::New(env, "No valid capture target specified. Please provide displayId, windowId, or bundleId")
            .Value());
    return deferred.Promise();
  }

  auto context = new CaptureContext{this, deferred};

  this->tsfn_video_ = Napi::ThreadSafeFunction::New(
      env, info.This().As<Napi::Object>().Get("emit").As<Napi::Function>(), "VideoFrameCallback", 8, 1, this,
      [](Napi::Env env, void *finalizeData, MediaCapture *context) {
        fprintf(stderr, "DEBUG: Video TSFN finalized\n");
      },
      context);

  this->tsfn_audio_ = Napi::ThreadSafeFunction::New(
      env, info.This().As<Napi::Object>().Get("emit").As<Napi::Function>(), "AudioEmitter", 0, 1,
      [this](Napi::Env) { this->tsfn_audio_ = nullptr; });

  this->tsfn_error_ = Napi::ThreadSafeFunction::New(
      env, info.This().As<Napi::Object>().Get("emit").As<Napi::Function>(), "ErrorEmitter", 0, 1,
      [this](Napi::Env) { this->tsfn_error_ = nullptr; });

  isCapturing_ = true;

  startMediaCapture(
      captureHandle_, captureConfig, &MediaCapture::VideoFrameCallback, &MediaCapture::AudioDataCallback,
      &MediaCapture::ExitCallback, context);

  if (captureConfig.bundleID) {
    free(captureConfig.bundleID);
  }

  deferred.Resolve(env.Undefined());
  return deferred.Promise();
}

static void StopMediaCaptureTrampoline(void *ctx) {
  auto context = static_cast<StopMediaCaptureContext *>(ctx);
  if (!context)
    return;

  MediaCapture *instance = context->instance; // Use direct pointer

  if (instance) {
    instance->RequestStopFromBackgroundThread(context);
  } else {
    fprintf(stderr, "DEBUG: StopMediaCaptureTrampoline - instance already destroyed\n");
    delete context;
  }
}

Napi::Value MediaCapture::StopCapture(const Napi::CallbackInfo &info) {
  Napi::Env         env = info.Env();
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

void MediaCapture::VideoFrameCallback(
    uint8_t *data, int32_t width, int32_t height, int32_t bytesPerRow, int32_t timestamp, const char *format,
    size_t actualBufferSize, void *ctx) {
  bool tsfn_acquired = false;

  try {
    if (!ctx || !data)
      return;
    auto          context  = static_cast<CaptureContext *>(ctx);
    MediaCapture *instance = context->instance; // Use direct pointer

    // Safely get instance
    if (!instance) {
      fputs("DEBUG: Ignoring video frame - instance no longer exists\n", stderr);
      return;
    }

    bool is_capturing = instance->isCapturing_.load();
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
    tsfn_acquired = true;

    const bool isJpeg = (format && strcmp(format, "jpeg") == 0);

    std::shared_ptr<uint8_t[]> dataCopy;
    size_t                     dataSize = 0;

    if (isJpeg) {
      dataSize = actualBufferSize;
      dataCopy = std::shared_ptr<uint8_t[]>(new uint8_t[dataSize]);
      memcpy(dataCopy.get(), data, dataSize);
    } else {
      dataSize = static_cast<size_t>(height) * static_cast<size_t>(bytesPerRow);
      dataCopy = std::shared_ptr<uint8_t[]>(new uint8_t[dataSize]);

      const size_t rowBytes =
          std::min(static_cast<size_t>(bytesPerRow), actualBufferSize / static_cast<size_t>(height));

      for (int32_t y = 0; y < height; y++) {
        const size_t srcOffset  = y * bytesPerRow;
        const size_t destOffset = y * bytesPerRow;

        if (srcOffset + rowBytes > actualBufferSize || destOffset + rowBytes > dataSize)
          break;
        memcpy(dataCopy.get() + destOffset, data + srcOffset, rowBytes);
      }
    }

    // Check instance state again
    if (!instance || !instance->isCapturing_.load()) {
      fputs("DEBUG: Skipping video callback - capture was stopped or instance destroyed\n", stderr);
      tsfn.Release();
      tsfn_acquired = false;
      return;
    }

    // Call callback with copied data
    auto dataCopy_shared = dataCopy;

    tsfn.NonBlockingCall([dataCopy_shared, width, height, bytesPerRow, timestamp, dataSize,
                          isJpeg](Napi::Env env, Napi::Function jsCallback) {
      try {
        Napi::HandleScope scope(env);

        // Convert data to ArrayBuffer
        Napi::ArrayBuffer buffer = Napi::ArrayBuffer::New(env, dataSize);
        memcpy(buffer.Data(), dataCopy_shared.get(), dataSize);

        // Create frame info object
        Napi::Object frame = Napi::Object::New(env);
        frame.Set("width", Napi::Number::New(env, width));
        frame.Set("height", Napi::Number::New(env, height));
        frame.Set("bytesPerRow", Napi::Number::New(env, bytesPerRow));
        frame.Set("timestamp", Napi::Number::New(env, timestamp / 1000.0)); // Convert to milliseconds
        frame.Set("isJpeg", Napi::Boolean::New(env, isJpeg));

        // Set data as Uint8Array
        frame.Set("data", Napi::Uint8Array::New(env, dataSize, buffer, 0));

        // Call callback function
        if (jsCallback.IsFunction()) {
          jsCallback.Call({Napi::String::New(env, "video-frame"), frame});
        } else {
          fprintf(stderr, "ERROR: Invalid JS callback for video frame\n");
        }
      } catch (const std::exception &e) {
        fprintf(stderr, "ERROR: Exception in video frame JS callback: %s\n", e.what());
      } catch (...) {
        fprintf(stderr, "ERROR: Unknown exception in video frame JS callback\n");
      }
    });

    tsfn.Release();
    tsfn_acquired = false;
  } catch (const std::bad_alloc &e) {
    fprintf(stderr, "ERROR: Memory allocation failed: %s\n", e.what());
  } catch (const std::exception &e) {
    fprintf(stderr, "ERROR: Exception in video frame copy: %s\n", e.what());
  } catch (...) {
    fprintf(stderr, "ERROR: Unknown exception in VideoFrameCallback\n");
  }

  // Always release TSFN
  if (tsfn_acquired) {
    auto          context  = static_cast<CaptureContext *>(ctx);
    MediaCapture *instance = context->instance;
    if (instance) { // Check direct pointer
      if (instance->tsfn_video_) {
        instance->tsfn_video_.Release();
      }
    }
  }
}

void MediaCapture::AudioDataCallback(
    int32_t channels, int32_t sampleRate, float *buffer, int32_t frameCount, void *ctx) {
  bool tsfn_acquired = false;

  try {
    if (!ctx)
      return;
    auto          context  = static_cast<CaptureContext *>(ctx);
    MediaCapture *instance = context->instance; // Use direct pointer

    // Check if instance is valid
    if (!instance) {
      fputs("DEBUG: Ignoring audio data - instance no longer exists\n", stderr);
      return;
    }

    bool is_capturing = instance->isCapturing_.load();
    if (!is_capturing) {
      fputs("DEBUG: Ignoring audio data - capture is inactive\n", stderr);
      return;
    }

    auto tsfn = instance->tsfn_audio_;
    if (!tsfn) {
      fputs("DEBUG: Audio TSFN is not available\n", stderr);
      return;
    }

    if (channels <= 0 || sampleRate <= 0 || frameCount <= 0 || !buffer) {
      fprintf(stderr, "ERROR: Invalid audio parameters\n");
      return;
    }

    size_t numSamples = static_cast<size_t>(channels) * static_cast<size_t>(frameCount);
    if (numSamples == 0 || numSamples > 1024 * 1024) {
      fprintf(stderr, "ERROR: Invalid audio buffer size\n");
      return;
    }

    // Call Acquire on TSFN
    napi_status status = tsfn.Acquire();
    if (status != napi_ok) {
      fputs("DEBUG: Failed to acquire audio TSFN\n", stderr);
      return;
    }
    tsfn_acquired = true;

    // Safely handle exceptions
    std::shared_ptr<float[]> audioCopy(new float[numSamples], std::default_delete<float[]>());
    std::memcpy(audioCopy.get(), buffer, numSamples * sizeof(float));

    // Check instance is valid again
    if (!instance || !instance->isCapturing_.load()) {
      fputs("DEBUG: Skipping audio callback - capture was stopped or instance destroyed\n", stderr);
      tsfn.Release();
      tsfn_acquired = false;
      return;
    }

    // Execute callback
    tsfn.NonBlockingCall(
        [audioCopy, channels, sampleRate, frameCount, numSamples](Napi::Env env, Napi::Function jsCallback) {
          try {
            Napi::HandleScope scope(env);

            Napi::ArrayBuffer buffer = Napi::ArrayBuffer::New(env, numSamples * sizeof(float));
            std::memcpy(buffer.Data(), audioCopy.get(), numSamples * sizeof(float));

            Napi::Float32Array audioData = Napi::Float32Array::New(env, numSamples, buffer, 0);

            if (jsCallback.IsFunction()) {
              jsCallback.Call(
                  {Napi::String::New(env, "audio-data"), audioData, Napi::Number::New(env, sampleRate),
                   Napi::Number::New(env, channels)});
            }
          } catch (const std::exception &e) {
            fprintf(stderr, "ERROR: Exception in audio data processing: %s\n", e.what());
          }
        });

    // Always release TSFN
    tsfn.Release();
    tsfn_acquired = false;
  } catch (const std::bad_alloc &e) {
    fprintf(stderr, "ERROR: Audio memory allocation failed: %s\n", e.what());
  } catch (const std::exception &e) {
    fprintf(stderr, "ERROR: Exception in audio data copy: %s\n", e.what());
  } catch (...) {
    fprintf(stderr, "ERROR: Unknown exception in AudioDataCallback\n");
  }

  // Release TSFN even on failure
  if (tsfn_acquired) {
    auto          context  = static_cast<CaptureContext *>(ctx);
    MediaCapture *instance = context->instance;
    if (instance) { // Check direct pointer
      if (instance->tsfn_audio_) {
        instance->tsfn_audio_.Release();
      }
    }
  }
}

void MediaCapture::ExitCallback(char *error, void *ctx) {
  if (!ctx) {
    fprintf(stderr, "ERROR: ExitCallback received null context\n");
    return;
  }

  // Safely manage context
  std::unique_ptr<CaptureContext> context_guard(static_cast<CaptureContext *>(ctx));
  MediaCapture                   *instance = context_guard->instance; // Use direct pointer

  if (!instance) {
    fprintf(stderr, "ERROR: ExitCallback received null instance\n");
    return;
  }

  // Use instance with reference count maintained
  bool was_capturing = instance->isCapturing_.exchange(false);

  std::string errorMessage;
  if (error) {
    errorMessage = std::string(error);
    fprintf(stderr, "DEBUG: Capture exited with error: %s\n", error);

    auto tsfn_error = instance->tsfn_error_;
    if (tsfn_error) {
      // Use direct reference to instance
      MediaCapture *inst_ptr = instance;

      tsfn_error.NonBlockingCall([errorMessage, inst_ptr](Napi::Env env, Napi::Function jsCallback) {
        try {
          Napi::HandleScope scope(env);
          if (jsCallback.IsFunction()) {
            Napi::Error err = Napi::Error::New(env, errorMessage);
            jsCallback.Call({Napi::String::New(env, "error"), err.Value()});
          }
        } catch (const std::exception &e) {
          fprintf(stderr, "ERROR: Exception in error callback: %s\n", e.what());
        }
      });
    }
  }

  // Remaining processing unchanged

  // Shutdown processing
  instance->SafeShutdown();
}

void MediaCapture::StopCallback(void *ctx) {
  if (!ctx)
    return;

  // Manage context with smart pointer to ensure deletion
  std::unique_ptr<StopContext> context_guard(static_cast<StopContext *>(ctx));
  MediaCapture                *instance = context_guard->instance; // Use direct pointer

  if (!instance) {
    // Instance already destroyed
    fprintf(stderr, "DEBUG: StopCallback - instance already destroyed\n");
    // context_guard will auto-release when out of scope
    return;
  }

  instance->isCapturing_ = false;

  // Remaining processing unchanged
}

void MediaCapture::ProcessStopMediaCaptureRequest() {
  std::unique_lock<std::mutex> lock(mutex_);

  if (!pendingMediaStopContext_)
    return;

  // Copy context and transfer ownership
  auto context             = std::unique_ptr<StopMediaCaptureContext>(pendingMediaStopContext_);
  pendingMediaStopContext_ = nullptr;
  lock.unlock(); // Release lock early

  try {
    Napi::HandleScope scope(context->deferred.Env());
    this->AbortAllThreadSafeFunctions();
    context->deferred.Resolve(context->deferred.Env().Undefined());
  } catch (const std::exception &e) {
    fprintf(stderr, "ERROR: Exception in ProcessStopMediaCaptureRequest: %s\n", e.what());
    try {
      context->deferred.Resolve(context->deferred.Env().Undefined());
    } catch (...) {
      fprintf(stderr, "ERROR: Failed to resolve promise in ProcessStopMediaCaptureRequest\n");
    }
  }
}

void MediaCapture::ProcessStopRequest() {
  std::unique_lock<std::mutex> lock(mutex_);

  if (!pendingStopContext_)
    return;

  // Copy context and transfer ownership
  auto context        = std::unique_ptr<StopContext>(pendingStopContext_);
  pendingStopContext_ = nullptr;
  lock.unlock(); // Release lock early

  try {
    Napi::HandleScope scope(context->deferred.Env());
    this->AbortAllThreadSafeFunctions();
    context->deferred.Resolve(context->deferred.Env().Undefined());
  } catch (const std::exception &e) {
    fprintf(stderr, "ERROR: Exception in ProcessStopRequest: %s\n", e.what());
    try {
      context->deferred.Resolve(context->deferred.Env().Undefined());
    } catch (...) {
      fprintf(stderr, "ERROR: Failed to resolve promise in ProcessStopRequest\n");
    }
  }
}

void MediaCapture::AbortAllThreadSafeFunctions() {
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

void MediaCapture::RequestStopFromBackgroundThread(StopMediaCaptureContext *context) {
  std::lock_guard<std::mutex> lock(mutex_);
  stopRequested_ = true;
  isCapturing_   = false;

  if (!pendingMediaStopContext_) {
    pendingMediaStopContext_ = context;

    if (tsfn_error_) {
      // Use this pointer directly
      MediaCapture *self = this;
      tsfn_error_.NonBlockingCall([self](Napi::Env env, Napi::Function jsCallback) {
        if (self) {
          self->ProcessStopMediaCaptureRequest();
        }
      });
    } else {
      delete context;
    }
  } else {
    delete context;
  }
}

void MediaCapture::RequestStopFromBackgroundThread(StopContext *context) {
  std::lock_guard<std::mutex> lock(mutex_);
  stopRequested_ = true;
  isCapturing_   = false;

  if (!pendingStopContext_) {
    pendingStopContext_ = context;
    if (tsfn_error_) {
      // Use this pointer directly
      MediaCapture *self = this;
      tsfn_error_.NonBlockingCall([self](Napi::Env env, Napi::Function jsCallback) {
        if (self) {
          self->ProcessStopRequest();
        }
      });
    } else {
      delete context;
    }
  } else {
    delete context;
  }
}