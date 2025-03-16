/**
 * @file capture.h
 * @brief Desktop/window audio and video capture APIs
 * 
 * This header defines structures and functions for capturing audio and video
 * from desktop displays and application windows on macOS and Windows.
 */

#ifndef _CAPTURE_H_
#define _CAPTURE_H_

#include <stdint.h>

/**
 * @struct DisplayInfo
 * @brief Display device information
 */
struct DisplayInfo {
  uint32_t displayID;  /**< Unique identifier for the display */
};

typedef struct DisplayInfo DisplayInfo;

/**
 * @struct WindowInfo
 * @brief Application window information
 */
struct WindowInfo {
  uint32_t windowID;   /**< Unique identifier for the window */
  char    *title;      /**< Window title */
};

typedef struct WindowInfo WindowInfo;

/**
 * @struct CaptureConfig
 * @brief Basic audio capture configuration
 */
struct CaptureConfig {
  int32_t  channels;   /**< Number of audio channels */
  int32_t  sampleRate; /**< Audio sample rate in Hz */
  uint32_t displayID;  /**< Target display ID (0 if not capturing from display) */
  uint32_t windowID;   /**< Target window ID (0 if not capturing from window) */
};

typedef struct CaptureConfig CaptureConfig;

/**
 * @struct MediaCaptureTargetC
 * @brief Media capture target information (display or window)
 */
struct MediaCaptureTargetC {
  int32_t  isDisplay;  /**< 1 if this target is a display, 0 otherwise */
  int32_t  isWindow;   /**< 1 if this target is a window, 0 otherwise */
  uint32_t displayID;  /**< Display identifier (valid if isDisplay==1) */
  uint32_t windowID;   /**< Window identifier (valid if isWindow==1) */
  int32_t  width;      /**< Width of the target in pixels */
  int32_t  height;     /**< Height of the target in pixels */
  char*    title;      /**< Title of the window or display name */
  char*    appName;    /**< Application name for window targets */
};

typedef struct MediaCaptureTargetC MediaCaptureTargetC;

/**
 * @struct MediaCaptureConfigC
 * @brief Media capture configuration (audio and video)
 */
struct MediaCaptureConfigC {
  float    frameRate;       /**< Target video frame rate */
  int32_t  quality;         /**< Encoding quality (0=high, 1=medium, 2=low) */
  int32_t  audioSampleRate; /**< Audio sample rate in Hz */
  int32_t  audioChannels;   /**< Number of audio channels */
  uint32_t displayID;       /**< Target display ID (0 if not capturing from display) */
  uint32_t windowID;        /**< Target window ID (0 if not capturing from window) */
  char*    bundleID;        /**< Application bundle ID for macOS (can be NULL) */
  int32_t  isElectron;      /**< 0=false(default), 1=true */
  int32_t  qualityValue;    /**< Precise JPEG quality value (0-100), overrides quality enum if > 0 */
  int32_t  imageFormat;     /**< Image format (0=jpeg, 1=raw) */
};

typedef struct MediaCaptureConfigC MediaCaptureConfigC;

/**
 * @struct AudioFormatInfoC
 * @brief Detailed audio format information
 */
struct AudioFormatInfoC {
  int32_t  sampleRate;      /**< Audio sample rate in Hz */
  int32_t  channelCount;    /**< Number of audio channels */
  uint32_t bytesPerFrame;   /**< Bytes per audio frame */
  uint32_t frameCount;      /**< Number of frames in buffer */
  int32_t  formatType;      /**< 1=PCM, 3=Float */
  int32_t  isInterleaved;   /**< 1 if channels are interleaved, 0 otherwise */
  uint32_t bitsPerChannel;  /**< Bits per channel (e.g., 32 for float) */
};

typedef struct AudioFormatInfoC AudioFormatInfoC;

/**
 * @brief Callback for media capture target enumeration
 * @param targets Array of capture targets
 * @param count Number of targets in array
 * @param error Error message (NULL if no error)
 * @param context User data pointer
 */
typedef void (*EnumerateMediaCaptureTargetsCallback)(MediaCaptureTargetC*, int32_t, char*, void*);

/**
 * @brief Callback for video frame data
 * @param data Pointer to raw video frame data
 * @param width Frame width in pixels
 * @param height Frame height in pixels
 * @param bytesPerRow Bytes per row (stride)
 * @param timestamp Frame timestamp in seconds as double
 * @param format Format string (e.g., "jpeg", "bgra")
 * @param size Size of data in bytes
 * @param context User data pointer
 */
typedef void (*MediaCaptureDataCallback)(uint8_t*, int32_t, int32_t, int32_t, double, const char*, size_t, void*);

/**
 * @brief Callback for audio data
 * @param channels Number of audio channels
 * @param sampleRate Audio sample rate
 * @param buffer Audio sample buffer (float)
 * @param frameCount Number of frames in buffer
 * @param context User data pointer
 */
typedef void (*MediaCaptureAudioDataCallback)(int32_t, int32_t, float*, int32_t, void*);

/**
 * @brief Callback for capture exit/error events
 * @param error Error message (NULL if normal exit)
 * @param context User data pointer 
 */
typedef void (*MediaCaptureExitCallback)(char*, void*);

/**
 * @brief Callback for desktop window enumeration
 * @param displays Array of available displays
 * @param displayCount Number of displays
 * @param windows Array of available windows
 * @param windowCount Number of windows
 * @param error Error message (NULL if no error)
 * @param context User data pointer
 */
typedef void (*EnumerateDesktopWindowsCallback)(DisplayInfo*, int32_t, WindowInfo*, int32_t, char*, void*);

/**
 * @brief Callback for audio data during capture
 * @param channels Number of audio channels
 * @param sampleRate Audio sample rate
 * @param buffer Audio sample buffer (float)
 * @param frameCount Number of frames in buffer
 * @param context User data pointer
 */
typedef void (*StartCaptureDataCallback)(int32_t, int32_t, float*, int32_t, void*);

/**
 * @brief Callback for capture exit/error events
 * @param error Error message (NULL if normal exit)
 * @param context User data pointer
 */
typedef void (*StartCaptureExitCallback)(char*, void*);

/**
 * @brief Callback after capture is stopped
 * @param context User data pointer
 */
typedef void (*StopCaptureCallback)(void*);

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Enumerate available desktop displays and windows
 * @param callback Function to receive results
 * @param context User data pointer passed to callback
 */
void enumerateDesktopWindows(EnumerateDesktopWindowsCallback, void*);

/**
 * @brief Create audio capture instance
 * @return Opaque pointer to capture instance
 */
void* createCapture(void);

/**
 * @brief Destroy audio capture instance
 * @param handle Pointer returned by createCapture
 */
void destroyCapture(void*);

/**
 * @brief Start audio capture
 * @param handle Pointer returned by createCapture
 * @param config Capture configuration
 * @param dataCallback Callback for audio data
 * @param exitCallback Callback for exit events
 * @param context User data pointer passed to callbacks
 */
void startCapture(void*, CaptureConfig, StartCaptureDataCallback, StartCaptureExitCallback, void*);

/**
 * @brief Stop audio capture
 * @param handle Pointer returned by createCapture
 * @param callback Callback invoked when stopped
 * @param context User data pointer passed to callback
 */
void stopCapture(void*, StopCaptureCallback, void*);

/**
 * @brief Enumerate available media capture targets
 * @param type Target type filter (0=all, 1=display, 2=window)
 * @param callback Function to receive results
 * @param context User data pointer passed to callback
 */
void enumerateMediaCaptureTargets(int32_t, EnumerateMediaCaptureTargetsCallback, void*);

/**
 * @brief Create media capture instance
 * @return Opaque pointer to media capture instance
 */
void* createMediaCapture(void);

/**
 * @brief Destroy media capture instance
 * @param handle Pointer returned by createMediaCapture
 */
void destroyMediaCapture(void*);

/**
 * @brief Start media capture (audio and video)
 * @param handle Pointer returned by createMediaCapture
 * @param config Capture configuration
 * @param videoCallback Callback for video frames
 * @param audioCallback Callback for audio data
 * @param exitCallback Callback for exit events
 * @param context User data pointer passed to callbacks
 */
void startMediaCapture(void*, MediaCaptureConfigC, MediaCaptureDataCallback, MediaCaptureAudioDataCallback, MediaCaptureExitCallback, void*);

/**
 * @brief Stop media capture
 * @param handle Pointer returned by createMediaCapture
 * @param callback Callback invoked when stopped
 * @param context User data pointer passed to callback
 */
void stopMediaCapture(void*, StopCaptureCallback, void*);

#ifdef __cplusplus
}
#endif

#endif /* _CAPTURE_H_ */
