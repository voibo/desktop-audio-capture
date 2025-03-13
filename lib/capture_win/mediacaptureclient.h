#pragma once

#include <memory>
#include <atomic>
#include <mutex>
#include <string>
#include "capture/capture.h"

class AudioCaptureImpl;
class VideoCaptureImpl;

class MediaCaptureClient {
public:
    MediaCaptureClient();
    ~MediaCaptureClient();

    // COM initialization and cleanup
    void initializeCom();
    void uninitializeCom();

    // Audio-only capture method
    bool startCapture(
        const MediaCaptureConfigC& config,
        MediaCaptureAudioDataCallback audioCallback,
        MediaCaptureExitCallback exitCallback,
        void* context
    );
    
    // Combined video and audio capture method
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

    // Target enumeration for available capture sources
    static void enumerateTargets(
        int targetType,
        EnumerateMediaCaptureTargetsCallback callback,
        void* context
    );

private:
    // Implementation objects for audio and video capture
    std::unique_ptr<AudioCaptureImpl> audioImpl;
    std::unique_ptr<VideoCaptureImpl> videoImpl;
    
    // Capture state management
    std::atomic<bool> isCapturing;
    std::mutex captureMutex;
    
    // Error handling
    std::string lastErrorMessage;
    void setError(const std::string& message);
};