/**
 * @file audiocaptureimpl.cc
 * @brief Windows implementation of audio capture functionality
 */
#include "audiocaptureimpl.h"
#include <cstring>

AudioCaptureImpl::AudioCaptureImpl() :
    hr(S_OK),
    enumerator(nullptr),
    device(nullptr),
    audioClient(nullptr),
    captureClient(nullptr),
    format(nullptr),
    numFramesInPacket(0),
    flags(0),
    buffer(nullptr),
    sampleRateConverter(nullptr),
    captureThread(nullptr),
    isCapturing(false),
    hEvent(NULL)
{
    memset(errorMsg, 0, sizeof(errorMsg));
}

AudioCaptureImpl::~AudioCaptureImpl() {
    if (isCapturing.load()) {
        stop(nullptr, nullptr);
    }
}

/**
 * Starts audio capture with specified configuration
 * 
 * @param config Media capture configuration
 * @param audioCallback Callback for audio data
 * @param exitCallback Callback for error handling
 * @param context User data passed to callbacks
 * @return True if capture starts successfully, false otherwise
 */
bool AudioCaptureImpl::start(
    const MediaCaptureConfigC& config,
    MediaCaptureAudioDataCallback audioCallback,
    MediaCaptureExitCallback exitCallback,
    void* context
) {
    this->config = config;
    
    if (config.audioChannels <= 0 || config.audioChannels > 2) {
        snprintf(errorMsg, sizeof(errorMsg)-1, "Unsupported value %d for audioChannels, only 1-2 channels supported", config.audioChannels);
        if (exitCallback) {
            exitCallback(errorMsg, context);
        }
        return false;
    }

    if (config.audioSampleRate <= 0) {
        snprintf(errorMsg, sizeof(errorMsg)-1, "Invalid sample rate: %d", config.audioSampleRate);
        if (exitCallback) {
            exitCallback(errorMsg, context);
        }
        return false;
    }

    // Initialize COM based on environment
    if (config.isElectron == 1) {
        // Skip COM initialization in Electron environment
        fprintf(stderr, "DEBUG: [Audio] Running in Electron environment, skipping COM initialization\n");
    } else {
        // Standard COM initialization
        hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
        if (hr != S_OK && hr != S_FALSE && hr != RPC_E_CHANGED_MODE) {
            snprintf(errorMsg, sizeof(errorMsg)-1, "Failed to initialize COM: 0x%lx", hr);
            if (exitCallback) {
                exitCallback(errorMsg, context);
            }
            return false;
        }
        
        // Log COM initialization status
        if (hr == S_OK) {
            fprintf(stderr, "DEBUG: [Audio] COM initialized successfully\n");
        } else if (hr == S_FALSE) {
            fprintf(stderr, "DEBUG: [Audio] COM already initialized on this thread\n");
        } else if (hr == RPC_E_CHANGED_MODE) {
            fprintf(stderr, "DEBUG: [Audio] COM already initialized with different threading model\n");
        }
    }

    // Initialize sample rate converter
    int error;
    sampleRateConverter = src_new(SRC_SINC_BEST_QUALITY, config.audioChannels, &error);
    if (!sampleRateConverter) {
        snprintf(errorMsg, sizeof(errorMsg)-1, "Could not create sample rate converter, error code: %d", error);
        if (exitCallback) {
            exitCallback(errorMsg, context);
        }
        return false;
    }

    // Create audio device enumerator
    hr = CoCreateInstance(
        __uuidof(MMDeviceEnumerator), 
        NULL, 
        CLSCTX_ALL,
        __uuidof(IMMDeviceEnumerator), 
        (void**)&enumerator
    );

    if (FAILED(hr)) {
        snprintf(errorMsg, sizeof(errorMsg)-1, "Error initializing audio capture: CoCreateInstance failed with 0x%lx", hr);
        if (exitCallback) {
            exitCallback(errorMsg, context);
        }
        return false;
    }

    // Select audio device based on config
    if (config.windowID == 101) {  // Microphone input
        hr = enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device);
    } else {  // System audio output
        hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    }

    if (FAILED(hr)) {
        snprintf(errorMsg, sizeof(errorMsg)-1, "Error getting audio endpoint: 0x%lx", hr);
        if (exitCallback) {
            exitCallback(errorMsg, context);
        }
        return false;
    }

    enumerator->Release();
    enumerator = nullptr;

    // Activate audio client
    hr = device->Activate(
        __uuidof(IAudioClient),
        CLSCTX_ALL,
        NULL,
        (void**)&audioClient
    );
    
    if (FAILED(hr)) {
        snprintf(errorMsg, sizeof(errorMsg)-1, "Error activating audio client: 0x%lx", hr);
        if (exitCallback) {
            exitCallback(errorMsg, context);
        }
        return false;
    }

    // Get audio format
    hr = audioClient->GetMixFormat(&format);
    if (FAILED(hr)) {
        snprintf(errorMsg, sizeof(errorMsg)-1, "Error getting audio format: 0x%lx", hr);
        if (exitCallback) {
            exitCallback(errorMsg, context);
        }
        return false;
    }

    // Verify audio format compatibility
    WAVEFORMATEXTENSIBLE* formatEx = reinterpret_cast<WAVEFORMATEXTENSIBLE*>(format);
    bool formatIsValid = (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
                         formatEx->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT &&
                         format->wBitsPerSample == 32);

    if (!formatIsValid) {
        snprintf(errorMsg, sizeof(errorMsg)-1, 
                "Unsupported audio format: wFormatTag=%d, wBitsPerSample=%d",
                format->wFormatTag, format->wBitsPerSample);
        if (exitCallback) {
            exitCallback(errorMsg, context);
        }
        return false;
    }

    // Create event for audio buffer notifications
    hEvent = CreateEvent(NULL, FALSE, FALSE, NULL);
    if (hEvent == NULL) {
        snprintf(errorMsg, sizeof(errorMsg)-1, "Failed to create audio event");
        if (exitCallback) {
            exitCallback(errorMsg, context);
        }
        return false;
    }

    // Set stream flags based on capture mode
    DWORD streamFlags;
    if (config.windowID == 101) {  // Microphone input
        streamFlags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
    } else {  // System audio output
        streamFlags = AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
    }

    // Initialize audio client
    const REFERENCE_TIME bufferDuration = 10000000;  // 1 second
    hr = audioClient->Initialize(
        AUDCLNT_SHAREMODE_SHARED,
        streamFlags,
        bufferDuration,
        0,
        format,
        NULL
    );

    if (FAILED(hr)) {
        snprintf(errorMsg, sizeof(errorMsg)-1, "Error initializing audio client: 0x%lx", hr);
        if (exitCallback) {
            exitCallback(errorMsg, context);
        }
        return false;
    }

    // Set event handle
    hr = audioClient->SetEventHandle(hEvent);
    if (FAILED(hr)) {
        snprintf(errorMsg, sizeof(errorMsg)-1, "Error setting audio event handle: 0x%lx", hr);
        if (exitCallback) {
            exitCallback(errorMsg, context);
        }
        return false;
    }

    // Get capture client service
    hr = audioClient->GetService(
        __uuidof(IAudioCaptureClient),
        (void**)&captureClient
    );
    if (FAILED(hr)) {
        snprintf(errorMsg, sizeof(errorMsg)-1, "Error getting audio capture client: 0x%lx", hr);
        if (exitCallback) {
            exitCallback(errorMsg, context);
        }
        return false;
    }

    // Start audio capture
    hr = audioClient->Start();
    if (FAILED(hr)) {
        snprintf(errorMsg, sizeof(errorMsg)-1, "Error starting audio capture: 0x%lx", hr);
        if (exitCallback) {
            exitCallback(errorMsg, context);
        }
        return false;
    }

    // Start capture thread
    isCapturing.store(true);
    captureThread = new std::thread(
        &AudioCaptureImpl::captureThreadProc,
        this, audioCallback, exitCallback, context
    );
    
    return true;
}

/**
 * Audio capture thread procedure
 * Continuously captures audio data and delivers it through the callback
 */
void AudioCaptureImpl::captureThreadProc(
    MediaCaptureAudioDataCallback audioCallback,
    MediaCaptureExitCallback exitCallback,
    void* context
) {
    while (isCapturing.load()) {
        DWORD waitResult = WaitForSingleObject(hEvent, INFINITE);
        if (waitResult != WAIT_OBJECT_0) {
            if (isCapturing.load() && exitCallback) {
                snprintf(errorMsg, sizeof(errorMsg)-1, "Error waiting for audio data: %lu", GetLastError());
                exitCallback(errorMsg, context);
            }
            break;
        }
        
        // Process audio packets
        UINT32 packetSize = 0;
        hr = captureClient->GetNextPacketSize(&packetSize);
        if (FAILED(hr)) {
            if (isCapturing.load() && exitCallback) {
                snprintf(errorMsg, sizeof(errorMsg)-1, "Error getting packet size: 0x%lx", hr);
                exitCallback(errorMsg, context);
            }
            break;
        }
        
        while (packetSize > 0) {
            // Get audio buffer
            hr = captureClient->GetBuffer(
                &buffer,
                &numFramesInPacket,
                &flags,
                NULL,
                NULL
            );
            
            if (FAILED(hr)) {
                if (isCapturing.load() && exitCallback) {
                    snprintf(errorMsg, sizeof(errorMsg)-1, "Error getting audio buffer: 0x%lx", hr);
                    exitCallback(errorMsg, context);
                }
                break;
            }
            
            // Process non-silent audio packets
            if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) == 0 && numFramesInPacket > 0) {
                float* audioData = reinterpret_cast<float*>(buffer);
                size_t numSamples = numFramesInPacket * format->nChannels;
                
                // Copy original data
                audioBufferOriginal.resize(numSamples);
                std::memcpy(audioBufferOriginal.data(), audioData, numSamples * sizeof(float));
                
                // Channel conversion (stereo to mono if needed)
                if (format->nChannels > 1 && config.audioChannels == 1) {
                    audioBufferConverted.resize(numFramesInPacket);
                    for (UINT32 i = 0; i < numFramesInPacket; ++i) {
                        float sum = 0.0f;
                        for (UINT16 ch = 0; ch < format->nChannels; ++ch) {
                            sum += audioBufferOriginal[i * format->nChannels + ch];
                        }
                        audioBufferConverted[i] = sum / format->nChannels;
                    }
                } else {
                    audioBufferConverted = audioBufferOriginal;
                }
                
                // Sample rate conversion if needed
                if (format->nSamplesPerSec != config.audioSampleRate) {
                    SRC_DATA srcData;
                    srcData.data_in = audioBufferConverted.data();
                    srcData.input_frames = numFramesInPacket;
                    srcData.src_ratio = static_cast<double>(config.audioSampleRate) / format->nSamplesPerSec;
                    
                    size_t outputFrames = static_cast<size_t>(ceil(numFramesInPacket * srcData.src_ratio));
                    audioBufferResampled.resize(outputFrames * config.audioChannels);
                    
                    srcData.data_out = audioBufferResampled.data();
                    srcData.output_frames = outputFrames;
                    srcData.end_of_input = 0;
                    
                    int error = src_process(sampleRateConverter, &srcData);
                    if (error != 0) {
                        if (isCapturing.load() && exitCallback) {
                            snprintf(errorMsg, sizeof(errorMsg)-1, "Error resampling audio: %s", src_strerror(error));
                            exitCallback(errorMsg, context);
                        }
                    } else if (audioCallback && srcData.output_frames_gen > 0) {
                        audioCallback(
                            config.audioChannels,
                            config.audioSampleRate,
                            audioBufferResampled.data(),
                            srcData.output_frames_gen,
                            context
                        );
                    }
                } else if (audioCallback) {
                    audioCallback(
                        config.audioChannels,
                        format->nSamplesPerSec,
                        audioBufferConverted.data(),
                        numFramesInPacket,
                        context
                    );
                }
            }
            
            // Release the buffer
            hr = captureClient->ReleaseBuffer(numFramesInPacket);
            if (FAILED(hr)) {
                if (isCapturing.load() && exitCallback) {
                    snprintf(errorMsg, sizeof(errorMsg)-1, "Error releasing audio buffer: 0x%lx", hr);
                    exitCallback(errorMsg, context);
                }
                break;
            }
            
            // Get next packet size
            hr = captureClient->GetNextPacketSize(&packetSize);
            if (FAILED(hr)) {
                if (isCapturing.load() && exitCallback) {
                    snprintf(errorMsg, sizeof(errorMsg)-1, "Error getting next packet size: 0x%lx", hr);
                    exitCallback(errorMsg, context);
                }
                break;
            }
        }
    }
}

/**
 * Stops audio capture and cleans up resources
 * 
 * @param stopCallback Callback called when stopped
 * @param context User data passed to callback
 */
void AudioCaptureImpl::stop(
    StopCaptureCallback stopCallback,
    void* context
) {
    isCapturing.store(false);
    
    // Signal the capture thread to exit
    if (hEvent) {
        SetEvent(hEvent);
    }
    
    // Wait for capture thread to finish
    if (captureThread && captureThread->joinable()) {
        captureThread->join();
        delete captureThread;
        captureThread = nullptr;
    }
    
    // Stop audio client
    if (audioClient) {
        audioClient->Stop();
    }
    
    // Resource cleanup
    if (sampleRateConverter) {
        src_delete(sampleRateConverter);
        sampleRateConverter = nullptr;
    }
    
    if (captureClient) {
        captureClient->Release();
        captureClient = nullptr;
    }
    
    if (audioClient) {
        audioClient->Release();
        audioClient = nullptr;
    }
    
    if (device) {
        device->Release();
        device = nullptr;
    }
    
    if (format) {
        CoTaskMemFree(format);
        format = nullptr;
    }
    
    if (hEvent) {
        CloseHandle(hEvent);
        hEvent = NULL;
    }
    
    // Clear audio buffers
    audioBufferOriginal.clear();
    audioBufferConverted.clear();
    audioBufferResampled.clear();
    
    // Notify completion
    if (stopCallback) {
        stopCallback(context);
    }
}