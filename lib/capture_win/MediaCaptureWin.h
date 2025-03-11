#ifndef _MEDIA_CAPTURE_WIN_H_
#define _MEDIA_CAPTURE_WIN_H_

#include <Windows.h>
#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include "capture/capture.h"

// Forward declarations
class MediaCaptureWin {
private:
    // Internal state tracking
    std::atomic<bool> captureInProgress;
    std::thread* captureThread;
    std::mutex captureMutex;
    std::condition_variable captureCV;

    // Configuration
    MediaCaptureConfigC config;
    
    // Callback storage
    MediaCaptureDataCallback videoCallback;
    MediaCaptureAudioDataCallback audioCallback;
    MediaCaptureExitCallback exitCallback;
    void* callbackContext;

    // Error handling
    char errorMessage[1024];
    
    // Target information cache
    std::vector<MediaCaptureTargetC> availableTargets;
    
    // Worker methods
    void captureThreadWorker();
    bool initializeCapture();
    void cleanupCapture();
    
    // Helper methods
    bool findCaptureTarget(uint32_t displayID, uint32_t windowID, const char* bundleID);
    void processAudioData(int32_t channels, int32_t sampleRate, float* data, int32_t frameCount);

public:
    MediaCaptureWin();
    ~MediaCaptureWin();

    // Main capture control methods
    bool startCapture(MediaCaptureConfigC config, 
                     MediaCaptureDataCallback videoCallback,
                     MediaCaptureAudioDataCallback audioCallback, 
                     MediaCaptureExitCallback exitCallback,
                     void* context);
    void stopCapture(StopCaptureCallback callback, void* context);
    
    // Target enumeration
    static void enumerateTargets(int32_t type, 
                                EnumerateMediaCaptureTargetsCallback callback,
                                void* context);

    const char* getErrorMessage() const;
};

#endif // _MEDIA_CAPTURE_WIN_H_