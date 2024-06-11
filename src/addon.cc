#include "audiocapture.h"
#include <napi.h>

Napi::Object InitAll(Napi::Env env, Napi::Object exports) {
  return AudioCapture::Init(env, exports);
}

NODE_API_MODULE(addon, InitAll)
