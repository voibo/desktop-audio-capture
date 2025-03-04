#include "mediacapture.h"
#include <iostream>
#include <string>

Napi::Object MediaCapture::Init(Napi::Env env, Napi::Object exports) {
  Napi::HandleScope scope(env);

  Napi::Function func = DefineClass(env, "MediaCapture", {
    InstanceMethod("startCapture", &MediaCapture::StartCapture),
    InstanceMethod("startCaptureEx", &MediaCapture::StartCaptureEx), // New extended API
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
  : Napi::ObjectWrap<MediaCapture>(info), isCapturing_(false), captureHandle_(nullptr), useExtendedAudio_(false) {
  Napi::Env env = info.Env();
  Napi::HandleScope scope(env);
  
  // Initialize native resource
  captureHandle_ = createMediaCapture();
}

MediaCapture::~MediaCapture() {
  // Stop capture if still running
  if (isCapturing_) {
    stopMediaCapture(captureHandle_, &MediaCapture::StopCallback, nullptr);
  }
  
  // Release native resource
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
  
  // Use capture context defined in header
  auto context = new CaptureContext { this, deferred };
  
  // Create thread-safe functions for events
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
  
  // Start capture
  isCapturing_ = true;
  useExtendedAudio_ = false;
  
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

// Start capture - Extended version with enhanced audio capabilities
Napi::Value MediaCapture::StartCaptureEx(const Napi::CallbackInfo& info) {
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
  captureConfig.audioSampleRate = 48000; // Optimal for audio quality
  captureConfig.audioChannels = 2;
  
  // Get values from JavaScript object (same as StartCapture)
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
  
  // Use capture context defined in header
  auto context = new CaptureContext { this, deferred };
  
  // Create thread-safe functions for events
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
  
  // For extended audio processing
  this->tsfn_audio_ex_ = Napi::ThreadSafeFunction::New(
    env,
    info.This().As<Napi::Object>().Get("emit").As<Napi::Function>(),
    "AudioExEmitter",
    0,
    1,
    [this](Napi::Env) {
      // Finalizer
      this->tsfn_audio_ex_ = nullptr;
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
  
  // Start capture with extended audio
  isCapturing_ = true;
  useExtendedAudio_ = true;
  
  startMediaCaptureEx(
    captureHandle_, 
    captureConfig, 
    &MediaCapture::VideoFrameCallback,
    &MediaCapture::AudioDataExCallback,
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

// Stop capture
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
  
  // Stop capture with native function
  stopMediaCapture(captureHandle_, [](void* ctx) {
    auto context = static_cast<StopContext*>(ctx);
    MediaCapture* instance = context->instance;
    
    // Update capture state
    instance->isCapturing_ = false;
    instance->useExtendedAudio_ = false;
    
    // Release thread-safe functions
    if (instance->tsfn_video_) {
      instance->tsfn_video_.Release();
    }
    
    if (instance->tsfn_audio_) {
      instance->tsfn_audio_.Release();
    }
    
    if (instance->tsfn_audio_ex_) {
      instance->tsfn_audio_ex_.Release();
    }
    
    if (instance->tsfn_error_) {
      instance->tsfn_error_.Release();
    }
    
    // Resolve promise
    context->deferred.Resolve(context->deferred.Env().Undefined());
    delete context;
  }, context);
  
  return deferred.Promise();
}

// Video frame callback
void MediaCapture::VideoFrameCallback(uint8_t* data, int32_t width, int32_t height, 
                                  int32_t bytesPerRow, int32_t timestamp, void* ctx) {
  auto context = static_cast<CaptureContext*>(ctx);
  auto instance = context->instance;
  
  // Do nothing if already terminated
  if (!instance->isCapturing_ || !instance->tsfn_video_) {
    return;
  }
  
  // Calculate buffer size
  size_t bufferSize = height * bytesPerRow;
  
  // Copy data to a new buffer
  uint8_t* videoBuffer = new uint8_t[bufferSize];
  memcpy(videoBuffer, data, bufferSize);
  
  // Emit event
  instance->tsfn_video_.NonBlockingCall([videoBuffer, width, height, bytesPerRow, timestamp, bufferSize](Napi::Env env, Napi::Function jsCallback) {
    // Create video data
    Napi::ArrayBuffer buffer = Napi::ArrayBuffer::New(env, bufferSize);
    uint8_t* bufferData = reinterpret_cast<uint8_t*>(buffer.Data());
    memcpy(bufferData, videoBuffer, bufferSize);
    delete[] videoBuffer; // Delete immediately
    
    Napi::Uint8Array videoData = Napi::Uint8Array::New(env, bufferSize, buffer, 0);
    
    // Frame object
    Napi::Object frame = Napi::Object::New(env);
    frame.Set("timestamp", Napi::Number::New(env, timestamp / 1000.0)); // Convert to seconds
    frame.Set("width", Napi::Number::New(env, width));
    frame.Set("height", Napi::Number::New(env, height));
    frame.Set("bytesPerRow", Napi::Number::New(env, bytesPerRow));
    frame.Set("videoData", videoData);
    
    // Emit event
    jsCallback.Call({Napi::String::New(env, "video-frame"), frame});
  });
}

// Standard audio data callback
void MediaCapture::AudioDataCallback(int32_t channels, int32_t sampleRate, 
                                 float* buffer, int32_t frameCount, void* ctx) {
  auto context = static_cast<CaptureContext*>(ctx);
  auto instance = context->instance;
  
  // Do nothing if already terminated or using extended audio format
  if (!instance->isCapturing_ || !instance->tsfn_audio_ || instance->useExtendedAudio_) {
    return;
  }
  
  // Calculate buffer size
  size_t bufferSize = frameCount * channels;
  
  // Copy data to a new buffer
  float* audioBuffer = new float[bufferSize];
  memcpy(audioBuffer, buffer, bufferSize * sizeof(float));
  
  // Emit event
  instance->tsfn_audio_.NonBlockingCall([audioBuffer, channels, sampleRate, frameCount, bufferSize](Napi::Env env, Napi::Function jsCallback) {
    // Create audio data
    Napi::ArrayBuffer buffer = Napi::ArrayBuffer::New(env, bufferSize * sizeof(float));
    float* bufferData = reinterpret_cast<float*>(buffer.Data());
    memcpy(bufferData, audioBuffer, bufferSize * sizeof(float));
    delete[] audioBuffer; // Delete immediately
    
    Napi::Float32Array audioData = Napi::Float32Array::New(env, bufferSize, buffer, 0);
    
    // Emit event
    jsCallback.Call({
      Napi::String::New(env, "audio-data"), 
      audioData,
      Napi::Number::New(env, sampleRate),
      Napi::Number::New(env, channels)
    });
  });
}

// Extended audio data callback
void MediaCapture::AudioDataExCallback(AudioFormatInfoC* format, float** channelData, int32_t channelCount, void* ctx) {
  auto context = static_cast<CaptureContext*>(ctx);
  auto instance = context->instance;
  
  // Do nothing if already terminated
  if (!instance->isCapturing_ || !instance->tsfn_audio_ex_) {
    return;
  }
  
  // Create a combined buffer from separate channels
  int32_t frameCount = format->frameCount;
  size_t totalSamples = frameCount * channelCount;
  
  // Copy channel data
  float* combinedBuffer = new float[totalSamples];
  
  if (format->isInterleaved) {
    // Data is already interleaved, just copy the first channel pointer
    memcpy(combinedBuffer, channelData[0], totalSamples * sizeof(float));
  } else {
    // Interleave the separate channel data
    for (int32_t f = 0; f < frameCount; f++) {
      for (int32_t c = 0; c < channelCount; c++) {
        combinedBuffer[f * channelCount + c] = channelData[c][f];
      }
    }
  }
  
  // Create a copy of format for use in the lambda
  auto formatCopy = new AudioFormatInfoC(*format);
  
  // Emit event
  instance->tsfn_audio_ex_.NonBlockingCall([combinedBuffer, formatCopy, totalSamples](Napi::Env env, Napi::Function jsCallback) {
    // Create audio data
    Napi::ArrayBuffer buffer = Napi::ArrayBuffer::New(env, totalSamples * sizeof(float));
    float* bufferData = reinterpret_cast<float*>(buffer.Data());
    memcpy(bufferData, combinedBuffer, totalSamples * sizeof(float));
    delete[] combinedBuffer; // Delete immediately
    
    Napi::Float32Array audioData = Napi::Float32Array::New(env, totalSamples, buffer, 0);
    
    // Create format info object
    Napi::Object formatInfo = Napi::Object::New(env);
    formatInfo.Set("sampleRate", Napi::Number::New(env, formatCopy->sampleRate));
    formatInfo.Set("channelCount", Napi::Number::New(env, formatCopy->channelCount));
    formatInfo.Set("bytesPerFrame", Napi::Number::New(env, formatCopy->bytesPerFrame));
    formatInfo.Set("frameCount", Napi::Number::New(env, formatCopy->frameCount));
    formatInfo.Set("formatType", Napi::Number::New(env, formatCopy->formatType));
    formatInfo.Set("isInterleaved", Napi::Boolean::New(env, formatCopy->isInterleaved == 1));
    formatInfo.Set("bitsPerChannel", Napi::Number::New(env, formatCopy->bitsPerChannel));
    
    delete formatCopy; // Delete the copied format
    
    // Emit event
    jsCallback.Call({
      Napi::String::New(env, "audio-data-ex"), 
      audioData,
      formatInfo
    });
  });
}

// Error callback
void MediaCapture::ExitCallback(char* error, void* ctx) {
  auto context = static_cast<CaptureContext*>(ctx);
  auto instance = context->instance;
  
  if (error) {
    // Emit error event if there's an error
    if (instance->tsfn_error_) {
      std::string errorMessage(error);
      
      instance->tsfn_error_.NonBlockingCall([errorMessage](Napi::Env env, Napi::Function jsCallback) {
        Napi::Error err = Napi::Error::New(env, errorMessage);
        jsCallback.Call({Napi::String::New(env, "error"), err.Value()});
      });
    }
  }
  
  // Update capture state
  instance->isCapturing_ = false;
  
  // Release thread-safe functions
  if (instance->tsfn_video_) {
    instance->tsfn_video_.Release();
  }
  
  if (instance->tsfn_audio_) {
    instance->tsfn_audio_.Release();
  }
  
  if (instance->tsfn_audio_ex_) {
    instance->tsfn_audio_ex_.Release();
  }
  
  if (instance->tsfn_error_) {
    instance->tsfn_error_.Release();
  }
  
  // Resolve promise (only on initial startup)
  if (context && !instance->isCapturing_) {
    context->deferred.Resolve(context->deferred.Env().Undefined());
    delete context;
  }
}

// Stop callback
void MediaCapture::StopCallback(void* ctx) {
  // This is just a placeholder
  // Actual implementation is in the lambda function in StopCapture
}