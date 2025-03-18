#include "audiocapture.h"

Napi::FunctionReference AudioCapture::_constructor;

Napi::Object AudioCapture::Init(Napi::Env env, Napi::Object exports) {
  Napi::Function func = DefineClass(
      env, "AudioCapture",
      {StaticMethod("enumerateDesktopWindows", &AudioCapture::EnumerateDesktopWindows),
       InstanceMethod("startCapture", &AudioCapture::StartCapture),
       InstanceMethod("stopCapture", &AudioCapture::StopCapture)});

  _constructor = Napi::Persistent(func);
  _constructor.SuppressDestruct();

  exports.Set("AudioCapture", func);

  return exports;
}

AudioCapture::AudioCapture(const Napi::CallbackInfo &info) : Napi::ObjectWrap<AudioCapture>(info) {
  _capturePtr = createCapture();
}

void AudioCapture::Finalize(Napi::Env env) {
  if (_capturePtr != nullptr) {
    destroyCapture(_capturePtr);
    _capturePtr = nullptr;
  }
}

Napi::Value AudioCapture::EnumerateDesktopWindows(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();

  Napi::Promise::Deferred deferred = Napi::Promise::Deferred::New(env);

  auto ctx = new EnumerateDesktopWindowsContext(
      Napi::ThreadSafeFunction::New(
          env, Napi::Function::New(env, [](const Napi::CallbackInfo &) {}), "EnumerateDesktopWindowsCallback", 0, 1),
      deferred);

  enumerateDesktopWindows(AudioCapture::EnumerateDesktopWindowsCallback, ctx);

  return deferred.Promise();
}

void AudioCapture::EnumerateDesktopWindowsCallback(
    DisplayInfo *displayInfo, int32_t displayCount, WindowInfo *windowInfo, int32_t windowCount, char *error,
    void *context) {
  auto ctx = reinterpret_cast<EnumerateDesktopWindowsContext *>(context);

  for (auto i = 0; i < displayCount; i++) {
    auto info = (displayInfo + i);
    ctx->displays.push_back({info->displayID});
  }
  for (auto i = 0; i < windowCount; i++) {
    // The title will be released after the callback returns,
    // so make a copy here
    auto info = (windowInfo + i);
    ctx->windows.push_back({info->windowID, strdup(info->title)});
  }

  auto callback = [](Napi::Env env, Napi::Function jsCallback, EnumerateDesktopWindowsContext *ctx) {
    auto displayArray = Napi::Array::New(env, ctx->displays.size());
    for (auto i = 0; i < ctx->displays.size(); i++) {
      auto info = ctx->displays[i];

      Napi::Object jsDisplayInfo = Napi::Object::New(env);
      jsDisplayInfo.Set("displayId", info.displayID);

      displayArray.Set(i, jsDisplayInfo);
    }

    auto windowArray = Napi::Array::New(env, ctx->windows.size());
    for (auto i = 0; i < ctx->windows.size(); i++) {
      auto info = ctx->windows[i];

      Napi::Object jsWindowInfo = Napi::Object::New(env);
      jsWindowInfo.Set("windowId", info.windowID);
      jsWindowInfo.Set("title", Napi::String::New(env, info.title));

      windowArray.Set(i, jsWindowInfo);

      // Release the copied title
      delete info.title;
    }
    // jsCallback.Call({displayArray, windowArray});
    auto resultArray = Napi::Array::New(env, 2);
    resultArray.Set(Napi::Number::New(env, 0), displayArray);
    resultArray.Set(Napi::Number::New(env, 1), windowArray);
    ctx->deferred.Resolve(resultArray);

    delete ctx;
  };

  napi_status status = ctx->callback.BlockingCall(ctx, callback);
  if (status != napi_ok) {
    delete ctx;
  }
}

Napi::Value AudioCapture::StartCapture(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();

  // CaptureConfig object.
  // {
  //   "channels": 1,
  //   "sampleRate": 16000,
  //   "displayId": 2,
  //   "windowId": 2,
  // }
  if (!info[0].IsObject()) {
    throw Napi::Error::New(env, "the first argument must be object");
  }
  Napi::Object config = info[0].As<Napi::Object>();

  // channels
  if (!config.Get("channels").IsNumber()) {
    throw Napi::Error::New(env, "config object does not have channels field");
  }
  int32_t channels = config.Get("channels").As<Napi::Number>().Int32Value();

  // sampleRate
  if (!config.Get("sampleRate").IsNumber()) {
    throw Napi::Error::New(env, "config object does not have sampleRate field");
  }
  int32_t sampleRate = config.Get("sampleRate").As<Napi::Number>().Int32Value();

  // displayId
  uint32_t displayId = 0;
  if (config.Get("displayId").IsNumber()) {
    displayId = config.Get("displayId").As<Napi::Number>().Uint32Value();
  }

  // windowId
  uint32_t windowId = 0;
  if (config.Get("windowId").IsNumber()) {
    windowId = config.Get("windowId").As<Napi::Number>().Uint32Value();
  }

  if (displayId == 0 && windowId == 0) {
    throw Napi::Error::New(env, "neither a displayId nor a windowId is specified.");
  }

  Napi::Function emit = info.This().As<Napi::Object>().Get("emit").As<Napi::Function>();

  auto ctx = new StartCaptureContext(
      Napi::ThreadSafeFunction::New(env, emit, "StartCaptureCallback", 0, 1),
      Napi::Persistent(info.This().As<Napi::Object>()));
  CaptureConfig cc = {channels, sampleRate, displayId, windowId};
  startCapture(_capturePtr, cc, AudioCapture::StartCaptureDataCallback, AudioCapture::StartCaptureExitCallback, ctx);

  return env.Undefined();
}

void AudioCapture::StartCaptureDataCallback(
    int32_t channels, int32_t sampleRate, float *pcm, int32_t samples, void *context) {
  // code of this function body executes in same thread as the invoker of the callback,
  // except for the callback code below.
  auto ctx = reinterpret_cast<StartCaptureContext *>(context);

  auto length = samples * channels;
  auto data   = new AudioCapture::StartCaptureCallbackData{};
  // TODO: メモリープールを用意する
  data->data   = new float[length];
  data->length = length;
  std::copy(pcm, pcm + length, data->data); // make copy of *pcm data for use from different thread

  auto callback = [ctx](Napi::Env env, Napi::Function jsCallback, StartCaptureCallbackData *data) {
    // code inside this block is called from a different thread than the invoker of the callback.
    // therefore we must not access the original data in *pcm (because it is not thread safe),
    // and instead only access our copy of the data in data->data.

    auto buffer = Napi::ArrayBuffer::New(env, data->length * sizeof(float));
    auto array  = Napi::Float32Array::New(env, data->length, buffer, 0);
    std::copy(data->data, data->data + data->length, array.Data());
    jsCallback.Call(ctx->refThis.Value(), {Napi::String::New(env, "data"), array});
    delete data->data;
    delete data;
  };

  // the following BlockingCall will add the add the callback function to the JS queue
  // and it will execute in a different thread.
  napi_status status = ctx->callback.BlockingCall(data, callback);
  if (status != napi_ok) {
    // TODO: handle error
  }
}

void AudioCapture::StartCaptureExitCallback(char *error, void *context) {
  auto ctx = reinterpret_cast<StartCaptureContext *>(context);

  if (error != nullptr) {
    auto callback = [error](Napi::Env env, Napi::Function jsCallback, StartCaptureContext *ctx) {
      auto error2 = Napi::Error::New(env, error);
      jsCallback.Call(ctx->refThis.Value(), {Napi::String::New(env, "error"), error2.Value()});

      delete ctx;
    };

    napi_status status = ctx->callback.BlockingCall(ctx, callback);
    if (status != napi_ok) {
      delete ctx;
    }
  } else {
    delete ctx;
  }
}

Napi::Value AudioCapture::StopCapture(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();

  Napi::Promise::Deferred deferred = Napi::Promise::Deferred::New(env);

  auto ctx = new StopCaptureContext(
      Napi::ThreadSafeFunction::New(
          env, Napi::Function::New(env, [](const Napi::CallbackInfo &) {}), "StopCaptureCallback", 0, 1),
      deferred);

  stopCapture(_capturePtr, AudioCapture::StopCaptureCallback, ctx);

  return deferred.Promise();
}

void AudioCapture::StopCaptureCallback(void *context) {
  auto ctx = reinterpret_cast<StopCaptureContext *>(context);

  auto callback = [](Napi::Env env, Napi::Function jsCallback, StopCaptureContext *ctx) {
    ctx->deferred.Resolve(env.Undefined());
    delete ctx;
  };

  napi_status status = ctx->callback.BlockingCall(ctx, callback);
  if (status != napi_ok) {
    delete ctx;
  }
}
