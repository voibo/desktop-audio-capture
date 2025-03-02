#ifndef _CAPTURE_H_
#define _CAPTURE_H_

#include <stdint.h>

struct DisplayInfo {
  uint32_t displayID;
};

typedef struct DisplayInfo DisplayInfo;

struct WindowInfo {
  uint32_t windowID;
  char    *title;
};

typedef struct WindowInfo WindowInfo;

struct CaptureConfig {
  int32_t  channels;
  int32_t  sampleRate;
  uint32_t displayID;
  uint32_t windowID;
};

typedef struct CaptureConfig CaptureConfig;

// MediaCaptureTarget 構造体
struct MediaCaptureTargetC {
  int32_t  isDisplay;
  int32_t  isWindow;
  uint32_t displayID;
  uint32_t windowID;
  int32_t  width;
  int32_t  height;
  char*    title;
  char*    appName;
};

typedef struct MediaCaptureTargetC MediaCaptureTargetC;

// MediaCaptureConfig 構造体
struct MediaCaptureConfigC {
  float    frameRate;
  int32_t  quality;
  int32_t  audioSampleRate;
  int32_t  audioChannels;
  uint32_t displayID;
  uint32_t windowID;
  char*    bundleID;
};

typedef struct MediaCaptureConfigC MediaCaptureConfigC;

// コールバック型定義
typedef void (*EnumerateMediaCaptureTargetsCallback)(MediaCaptureTargetC*, int32_t, char*, void*);
typedef void (*MediaCaptureDataCallback)(uint8_t*, int32_t, int32_t, int32_t, int32_t, void*);
typedef void (*MediaCaptureAudioDataCallback)(int32_t, int32_t, float*, int32_t, void*);
typedef void (*MediaCaptureExitCallback)(char*, void*);

typedef void (*EnumerateDesktopWindowsCallback)(DisplayInfo *, int32_t, WindowInfo *, int32_t, char *, void *);
typedef void (*StartCaptureDataCallback)(int32_t, int32_t, float *, int32_t, void *);
typedef void (*StartCaptureExitCallback)(char *, void *);
typedef void (*StopCaptureCallback)(void *);

#ifdef __cplusplus
extern "C" {
#endif

void  enumerateDesktopWindows(EnumerateDesktopWindowsCallback, void *);
void *createCapture(void);
void  destroyCapture(void *);
void  startCapture(void *, CaptureConfig, StartCaptureDataCallback, StartCaptureExitCallback, void *);
void  stopCapture(void *, StopCaptureCallback, void *);

void  enumerateMediaCaptureTargets(int32_t, EnumerateMediaCaptureTargetsCallback, void*);
void* createMediaCapture(void);
void  destroyMediaCapture(void*);
void  startMediaCapture(void*, MediaCaptureConfigC, MediaCaptureDataCallback, MediaCaptureAudioDataCallback, MediaCaptureExitCallback, void*);
void  stopMediaCapture(void*, StopCaptureCallback, void*);

#ifdef __cplusplus
}
#endif

#endif
