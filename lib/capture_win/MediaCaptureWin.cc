#include "capture/capture.h"
#include "mediacaptureclient.h"
#include <memory>

/**
 * C API implementation for MediaCaptureWin
 *
 * This file implements the C interface defined in capture.h
 * and delegates to the C++ MediaCaptureClient class
 */

extern "C" {

/**
 * Create a media capture instance
 */
void *createMediaCapture(void) {
  MediaCaptureClient *client = new MediaCaptureClient();
  client->initializeCom();
  return client;
}

/**
 * Destroy a media capture instance
 */
void destroyMediaCapture(void *capture) {
  if (capture) {
    MediaCaptureClient *client = static_cast<MediaCaptureClient *>(capture);
    client->uninitializeCom();
    delete client;
  }
}

/**
 * Enumerate available media capture targets
 */
void enumerateMediaCaptureTargets(int32_t targetType, EnumerateMediaCaptureTargetsCallback callback, void *context) {
  MediaCaptureClient::enumerateTargets(targetType, callback, context);
}

/**
 * Start media capture
 */
void startMediaCapture(
    void *capture, MediaCaptureConfigC config, MediaCaptureDataCallback videoCallback,
    MediaCaptureAudioDataCallback audioCallback, MediaCaptureExitCallback exitCallback, void *context) {
  if (!capture) {
    if (exitCallback) {
      exitCallback("Invalid media capture instance", context);
    }
    return;
  }

  MediaCaptureClient *client = static_cast<MediaCaptureClient *>(capture);

  client->startCapture(config, videoCallback, audioCallback, exitCallback, context);
}

/**
 * Stop media capture
 */
void stopMediaCapture(void *capture, StopCaptureCallback stopCallback, void *context) {
  if (!capture) {
    if (stopCallback) {
      stopCallback(context);
    }
    return;
  }

  MediaCaptureClient *client = static_cast<MediaCaptureClient *>(capture);
  client->stopCapture(stopCallback, context);
}

} // extern "C"