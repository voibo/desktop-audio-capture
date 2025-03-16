/**
 * @file mediacapture.h
 * @brief Node.js native addon for desktop audio and video capture
 *
 * This header defines the MediaCapture class which provides JavaScript bindings
 * for the desktop-audio-capture library. It handles asynchronous operations,
 * callback management, and resource lifecycle for audio and video capture.
 */
#ifndef MEDIA_CAPTURE_H
#define MEDIA_CAPTURE_H

#include <napi.h>
#include <mutex>
#include <thread>
#include <atomic>
#include <vector>
#include <memory>
#include <cstring>
#include <stdexcept>
#include "../include/capture/capture.h"

class MediaCapture;

/**
 * @struct ContextBase
 * @brief Base context structure for callback operations
 *
 * Provides the MediaCapture instance reference to callbacks,
 * allowing them to interact with the instance.
 */
struct ContextBase {
  /** The MediaCapture instance this context belongs to */
  MediaCapture* instance;
  
  /**
   * @brief Constructor
   * @param inst Pointer to MediaCapture instance
   */
  ContextBase(MediaCapture* inst) : instance(inst) {}
  
  /**
   * @brief Virtual destructor for proper inheritance cleanup
   */
  virtual ~ContextBase() = default;
};

/**
 * @struct CaptureContext
 * @brief Context for capture start operations
 *
 * Extends ContextBase with a Promise deferred for asynchronous resolution
 * of capture start operations.
 */
struct CaptureContext : public ContextBase {
  /** Promise deferred to resolve/reject when operation completes */
  Napi::Promise::Deferred deferred;
  
  /**
   * @brief Constructor
   * @param inst Pointer to MediaCapture instance
   * @param def Promise deferred object for async resolution
   */
  CaptureContext(MediaCapture* inst, Napi::Promise::Deferred def) 
    : ContextBase(inst), deferred(std::move(def)) {}
};

/**
 * @struct StopContext
 * @brief Context for basic capture stop operations
 *
 * Extends ContextBase with a Promise deferred for asynchronous resolution
 * of capture stop operations.
 */
struct StopContext : public ContextBase {
  /** Promise deferred to resolve/reject when operation completes */
  Napi::Promise::Deferred deferred;
  
  /**
   * @brief Constructor
   * @param inst Pointer to MediaCapture instance
   * @param def Promise deferred object for async resolution
   */
  StopContext(MediaCapture* inst, Napi::Promise::Deferred def) 
    : ContextBase(inst), deferred(std::move(def)) {}
};

/**
 * @struct StopMediaCaptureContext
 * @brief Context for media capture stop operations
 *
 * Extends ContextBase with a Promise deferred for asynchronous resolution
 * of media capture stop operations.
 */
struct StopMediaCaptureContext : public ContextBase {
  /** Promise deferred to resolve/reject when operation completes */
  Napi::Promise::Deferred deferred;
  
  /**
   * @brief Constructor
   * @param inst Pointer to MediaCapture instance
   * @param def Promise deferred object for async resolution
   */
  StopMediaCaptureContext(MediaCapture* inst, Napi::Promise::Deferred def) 
    : ContextBase(inst), deferred(std::move(def)) {}
};

/**
 * @class MediaCapture
 * @brief Node.js binding for desktop audio and video capture functionality
 *
 * Provides JavaScript interface to native capture functionality including:
 * - Enumerating available capture targets (displays, windows, audio devices)
 * - Starting audio and/or video capture
 * - Streaming captured data to JavaScript via callbacks
 * - Safely stopping capture operations
 */
class MediaCapture : public Napi::ObjectWrap<MediaCapture> {
 public:
  /**
   * @brief Initialize the class and export it to JavaScript
   * @param env Node.js environment
   * @param exports Target exports object
   * @return The populated exports object
   */
  static Napi::Object Init(Napi::Env env, Napi::Object exports);
  
  /**
   * @brief Constructor - creates a new MediaCapture instance
   * @param info JavaScript call information
   */
  MediaCapture(const Napi::CallbackInfo& info);
  
  /**
   * @brief Destructor - ensures safe cleanup
   */
  ~MediaCapture();
  
  /**
   * @brief Abort all thread-safe functions to prevent further callbacks
   * 
   * Called during shutdown to ensure no more JavaScript callbacks are invoked.
   */
  void AbortAllThreadSafeFunctions();
  
  /**
   * @brief Request stop operation from a background thread using StopMediaCaptureContext
   * @param context The context containing the promise to resolve
   */
  void RequestStopFromBackgroundThread(StopMediaCaptureContext* context);
  
  /**
   * @brief Request stop operation from a background thread using StopContext
   * @param context The context containing the promise to resolve
   */
  void RequestStopFromBackgroundThread(StopContext* context);
  
  /**
   * @brief Process pending media capture stop request
   * 
   * Resolves the pending promise and cleans up the context.
   */
  void ProcessStopMediaCaptureRequest();
  
  /**
   * @brief Process pending capture stop request
   * 
   * Resolves the pending promise and cleans up the context.
   */
  void ProcessStopRequest();

 private:
  /**
   * @brief JavaScript method to enumerate available capture targets
   * @param info JavaScript call information
   * @return Promise that resolves with available targets
   */
  static Napi::Value EnumerateTargets(const Napi::CallbackInfo& info);
  
  /**
   * @brief JavaScript method to start capture
   * @param info JavaScript call information with capture configuration
   * @return Promise that resolves when capture starts successfully
   */
  Napi::Value StartCapture(const Napi::CallbackInfo& info);
  
  /**
   * @brief JavaScript method to stop capture
   * @param info JavaScript call information
   * @return Promise that resolves when capture stops successfully
   */
  Napi::Value StopCapture(const Napi::CallbackInfo& info);
  
  /**
   * @brief Perform safe shutdown, stopping capture and cleaning up resources
   */
  void SafeShutdown();

  /** Handle to native capture implementation */
  void* captureHandle_;
  
  /** Flag indicating if capture is currently active */
  std::atomic<bool> isCapturing_{false};
  
  /** Thread-safe function for video frame callbacks */
  Napi::ThreadSafeFunction tsfn_video_;
  
  /** Thread-safe function for audio data callbacks */
  Napi::ThreadSafeFunction tsfn_audio_;
  
  /** Thread-safe function for error callbacks */
  Napi::ThreadSafeFunction tsfn_error_;
  
  /**
   * @name Native Callbacks
   * Static callback functions for the native capture implementation
   * @{
   */
  
  /**
   * @brief Callback for video frame data
   * @param data Raw frame data buffer
   * @param width Frame width in pixels
   * @param height Frame height in pixels
   * @param bytesPerRow Number of bytes per row (stride)
   * @param timestamp Frame timestamp in seconds since Unix epoch (double)
   * @param format String indicating frame format (e.g., "jpeg")
   * @param actualBufferSize Actual size of the data buffer in bytes
   * @param ctx User context pointer (ContextBase*)
   */
  static void VideoFrameCallback(uint8_t* data, int32_t width, int32_t height, 
                               int32_t bytesPerRow, double timestamp,
                               const char* format, size_t actualBufferSize, void* ctx);
  
  /**
   * @brief Callback for audio data
   * @param channels Number of audio channels
   * @param sampleRate Audio sample rate in Hz
   * @param buffer Audio sample buffer (float)
   * @param frameCount Number of audio frames
   * @param ctx User context pointer (ContextBase*)
   */
  static void AudioDataCallback(int32_t channels, int32_t sampleRate, 
                              float* buffer, int32_t frameCount, void* ctx);
  
  /**
   * @brief Callback for capture errors or exit events
   * @param error Error message (null if normal exit)
   * @param ctx User context pointer (ContextBase*)
   */
  static void ExitCallback(char* error, void* ctx);
  
  /**
   * @brief Callback when capture has been stopped
   * @param ctx User context pointer (ContextBase*)
   */
  static void StopCallback(void* ctx);
  /** @} */

  /** Mutex for thread synchronization */
  std::mutex mutex_;
  
  /** Flag indicating a stop has been requested */
  std::atomic<bool> stopRequested_{false};
  
  /** Pending stop context for normal capture */
  StopContext* pendingStopContext_{nullptr};
  
  /** Pending stop context for media capture */
  StopMediaCaptureContext* pendingMediaStopContext_{nullptr};
};

#endif // MEDIA_CAPTURE_H