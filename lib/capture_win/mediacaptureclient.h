#pragma once

#include <memory>
#include <atomic>
#include <mutex>
#include <string>
#include "capture/capture.h"

// 前方宣言
class AudioCaptureImpl;
class VideoCaptureImpl;

class MediaCaptureClient {
public:
    MediaCaptureClient();
    ~MediaCaptureClient();

    // COM initialization
    void initializeCom();
    void uninitializeCom();

    // Audio capture methods
    bool startCapture(
        const MediaCaptureConfigC& config,
        MediaCaptureAudioDataCallback audioCallback,
        MediaCaptureExitCallback exitCallback,
        void* context
    );
    
    // Video and audio capture methods
    bool startCapture(
        const MediaCaptureConfigC& config,
        MediaCaptureDataCallback videoCallback,
        MediaCaptureAudioDataCallback audioCallback,
        MediaCaptureExitCallback exitCallback,
        void* context
    );

    void stopCapture(
        StopCaptureCallback stopCallback,
        void* context
    );

    // Target enumeration
    static void enumerateTargets(
        int targetType,
        EnumerateMediaCaptureTargetsCallback callback,
        void* context
    );

private:
    // Implementation objects
    std::unique_ptr<AudioCaptureImpl> audioImpl;
    std::unique_ptr<VideoCaptureImpl> videoImpl;
    
    // State management
    std::atomic<bool> isCapturing;
    std::mutex captureMutex;
    
    // Error handling
    std::string lastErrorMessage;
    void setError(const std::string& message);
};