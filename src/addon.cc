#include "audiocapture.h"
#include "mediacapture.h"
#include <napi.h>

Napi::Object InitAll(Napi::Env env, Napi::Object exports) {
  exports = AudioCapture::Init(env, exports);
  exports = MediaCapture::Init(env, exports);
  return exports;
}

NODE_API_MODULE(addon, InitAll)