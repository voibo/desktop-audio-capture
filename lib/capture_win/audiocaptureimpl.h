#pragma once

#include <Windows.h>
#include <mmdeviceapi.h>
#include <Audioclient.h>
#include <vector>
#include <thread>
#include <atomic>
#include <samplerate.h>
#include "capture/capture.h"

class AudioCaptureImpl {
public:
    AudioCaptureImpl();
    ~AudioCaptureImpl();

    bool start(
        const MediaCaptureConfigC& config,
        MediaCaptureAudioDataCallback audioCallback,
        MediaCaptureExitCallback exitCallback,
        void* context
    );

    void stop(
        StopCaptureCallback stopCallback,
        void* context
    );

private:
    // COM resources for Windows audio capture
    HRESULT hr;
    IMMDeviceEnumerator* enumerator;
    IMMDevice* device;
    IAudioClient* audioClient;
    IAudioCaptureClient* captureClient;
    WAVEFORMATEX* format;

    // Audio processing parameters
    UINT32 numFramesInPacket;
    DWORD flags;
    BYTE* buffer;
    
    // Sample rate conversion resources
    SRC_STATE* sampleRateConverter;
    std::vector<float> audioBufferOriginal;
    std::vector<float> audioBufferConverted;
    std::vector<float> audioBufferResampled;

    // Thread management resources
    std::thread* captureThread;
    std::atomic<bool> isCapturing;
    HANDLE hEvent;

    // Configuration and error handling
    MediaCaptureConfigC config;
    char errorMsg[1024];

    // Audio capture thread worker function
    void captureThreadProc(
        MediaCaptureAudioDataCallback audioCallback,
        MediaCaptureExitCallback exitCallback,
        void* context
    );
};