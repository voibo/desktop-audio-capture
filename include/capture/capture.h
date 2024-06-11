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

#ifdef __cplusplus
}
#endif

#endif
