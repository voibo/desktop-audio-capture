/**
 * @file audiocaptureimpl.h
 * @brief Windows audio capture implementation using Windows Core Audio API
 * 
 * This class implements audio capture functionality for Windows systems using
 * the Windows Core Audio APIs (WASAPI). It supports capturing both system audio output
 * and microphone input with configurable parameters.
 */
#pragma once

#include <Windows.h>
#include <mmdeviceapi.h>
#include <Audioclient.h>
#include <vector>
#include <thread>
#include <atomic>
#include <samplerate.h>
#include "capture/capture.h"

/**
 * @class AudioCaptureImpl
 * @brief Windows-specific implementation of audio capture
 * 
 * Handles the low-level audio capture functionality for Windows using WASAPI.
 * Supports system audio capture (loopback) and microphone input.
 */
class AudioCaptureImpl {
public:
    /**
     * @brief Constructor - initializes resources to default values
     */
    AudioCaptureImpl();
    
    /**
     * @brief Destructor - ensures capture is stopped and resources are released
     */
    ~AudioCaptureImpl();

    /**
     * @brief Start audio capture with specified configuration
     * 
     * @param config Media capture configuration including sample rate, channels, etc.
     * @param audioCallback Function called when audio data is available
     * @param exitCallback Function called when an error occurs
     * @param context User data passed to callbacks
     * @return true if capture started successfully, false otherwise
     */
    bool start(
        const MediaCaptureConfigC& config,
        MediaCaptureAudioDataCallback audioCallback,
        MediaCaptureExitCallback exitCallback,
        void* context
    );

    /**
     * @brief Stop audio capture and release resources
     * 
     * @param stopCallback Function called when capture has stopped
     * @param context User data passed to callback
     */
    void stop(
        StopCaptureCallback stopCallback,
        void* context
    );

private:
    /** HRESULT status code for COM operations */
    HRESULT hr;
    
    /** Audio device enumerator interface */
    IMMDeviceEnumerator* enumerator;
    
    /** Audio device interface */
    IMMDevice* device;
    
    /** Audio client interface for endpoint device */
    IAudioClient* audioClient;
    
    /** Audio capture client interface */
    IAudioCaptureClient* captureClient;
    
    /** Audio format specification */
    WAVEFORMATEX* format;

    /** Number of frames in current audio packet */
    UINT32 numFramesInPacket;
    
    /** Buffer flags (silent, etc.) */
    DWORD flags;
    
    /** Pointer to audio data buffer */
    BYTE* buffer;
    
    /** Sample rate conversion state object */
    SRC_STATE* sampleRateConverter;
    
    /** Buffer for original audio samples */
    std::vector<float> audioBufferOriginal;
    
    /** Buffer for channel-converted audio samples */
    std::vector<float> audioBufferConverted;
    
    /** Buffer for resampled audio data */
    std::vector<float> audioBufferResampled;

    /** Audio capture worker thread */
    std::thread* captureThread;
    
    /** Flag to control capture thread execution */
    std::atomic<bool> isCapturing;
    
    /** Event handle for audio buffer notifications */
    HANDLE hEvent;

    /** Current capture configuration */
    MediaCaptureConfigC config;
    
    /** Buffer for error messages */
    char errorMsg[1024];

    /**
     * @brief Audio capture thread worker function
     * 
     * This function runs in a separate thread and continuously captures
     * audio data, processes it (format conversion, resampling), and
     * delivers it through the callback.
     * 
     * @param audioCallback Function to call with processed audio data
     * @param exitCallback Function to call if an error occurs
     * @param context User data passed to callbacks
     */
    void captureThreadProc(
        MediaCaptureAudioDataCallback audioCallback,
        MediaCaptureExitCallback exitCallback,
        void* context
    );
};