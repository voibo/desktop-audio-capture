#ifndef _AUDIO_CAPTURE_H_
#define _AUDIO_CAPTURE_H_

#include <fstream>
#include <napi.h>
#include <vector>

#include "capture/capture.h"

class ThreadSafeContext {
public:
  ThreadSafeContext(Napi::ThreadSafeFunction callback) : callback(callback) {}
  ~ThreadSafeContext() {
    callback.Release();
  }

  Napi::ThreadSafeFunction callback;
};

class AudioCapture : public Napi::ObjectWrap<AudioCapture> {
public:
  static Napi::Object Init(Napi::Env env, Napi::Object exports);

  AudioCapture(const Napi::CallbackInfo &info);
  void Finalize(Napi::Env env) override;

private:
  class EnumerateDesktopWindowsContext : public ThreadSafeContext {
  public:
    EnumerateDesktopWindowsContext(Napi::ThreadSafeFunction callback, Napi::Promise::Deferred deferred) :
        ThreadSafeContext(callback),
        deferred(deferred) {}

    Napi::Promise::Deferred  deferred;
    std::vector<DisplayInfo> displays;
    std::vector<WindowInfo>  windows;
  };

  typedef struct {
    float  *data;
    int32_t length;
  } StartCaptureCallbackData;

  class StartCaptureContext : public ThreadSafeContext {
  public:
    StartCaptureContext(Napi::ThreadSafeFunction callback, Napi::ObjectReference refThis) :
        ThreadSafeContext(callback),
        refThis(std::move(refThis)) {}
    ~StartCaptureContext() {
      refThis.Reset();
    }

    Napi::ObjectReference refThis;
  };

  class StopCaptureContext : public ThreadSafeContext {
  public:
    StopCaptureContext(Napi::ThreadSafeFunction callback, Napi::Promise::Deferred deferred) :
        ThreadSafeContext(callback),
        deferred(deferred) {}

    Napi::Promise::Deferred deferred;
  };

  static Napi::Value EnumerateDesktopWindows(const Napi::CallbackInfo &info);
  Napi::Value        StartCapture(const Napi::CallbackInfo &info);
  Napi::Value        StopCapture(const Napi::CallbackInfo &info);

  static void EnumerateDesktopWindowsCallback(
      DisplayInfo *displayInfo, int32_t displayCount, WindowInfo *windowInfo, int32_t windowCount, char *error,
      void *context);
  static void
  StartCaptureDataCallback(int32_t channels, int32_t sampleRate, float *pcm, int32_t samples, void *context);
  static void StartCaptureExitCallback(char *error, void *context);
  static void StopCaptureCallback(void *context);

  static Napi::FunctionReference _constructor;
  void                          *_capturePtr = nullptr;
};

#endif
