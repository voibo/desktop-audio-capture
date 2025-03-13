#include "audiocaptureimpl.h"
#include <cstring>

// コンストラクタとデストラクタの実装（重複しているもの削除）
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
    // Ensure capture is stopped
    if (isCapturing.load()) {
        stop(nullptr, nullptr);
    }
}

// 残りのメソッド実装はそのまま
bool AudioCaptureImpl::start(
    const MediaCaptureConfigC& config,
    MediaCaptureAudioDataCallback audioCallback,
    MediaCaptureExitCallback exitCallback,
    void* context
) {
    this->config = config;
    
    // Validate configuration
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

    // Initialize COM if not already initialized
    hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (hr != S_OK && hr != S_FALSE) {
        snprintf(errorMsg, sizeof(errorMsg)-1, "Failed to initialize COM: 0x%lx", hr);
        if (exitCallback) {
            exitCallback(errorMsg, context);
        }
        return false;
    }

    // Setup sample rate converter
    int error;
    sampleRateConverter = src_new(SRC_SINC_BEST_QUALITY, config.audioChannels, &error);
    if (!sampleRateConverter) {
        snprintf(errorMsg, sizeof(errorMsg)-1, "Could not create sample rate converter, error code: %d", error);
        if (exitCallback) {
            exitCallback(errorMsg, context);
        }
        return false;
    }

    // Create device enumerator
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

    // Get device based on windowID in config
    if (config.windowID == 101) {  // Microphone input
        hr = enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device);
    } else {  // System audio output (default)
        hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    }

    if (FAILED(hr)) {
        snprintf(errorMsg, sizeof(errorMsg)-1, "Error getting audio endpoint: 0x%lx", hr);
        if (exitCallback) {
            exitCallback(errorMsg, context);
        }
        return false;
    }

    // Release enumerator
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

    // Get mix format
    hr = audioClient->GetMixFormat(&format);
    if (FAILED(hr)) {
        snprintf(errorMsg, sizeof(errorMsg)-1, "Error getting audio format: 0x%lx", hr);
        if (exitCallback) {
            exitCallback(errorMsg, context);
        }
        return false;
    }

    // Verify format
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

    // Create event for buffer ready notification
    hEvent = CreateEvent(NULL, FALSE, FALSE, NULL);
    if (hEvent == NULL) {
        snprintf(errorMsg, sizeof(errorMsg)-1, "Failed to create audio event");
        if (exitCallback) {
            exitCallback(errorMsg, context);
        }
        return false;
    }

    // Initialize audio client with appropriate flags
    DWORD streamFlags;
    if (config.windowID == 101) {  // Microphone input
        streamFlags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
    } else {  // System audio output
        streamFlags = AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
    }

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

    // Get capture client
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

    // Start audio client
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

void AudioCaptureImpl::captureThreadProc(
    MediaCaptureAudioDataCallback audioCallback,
    MediaCaptureExitCallback exitCallback,
    void* context
) {
    while (isCapturing.load()) {
        // Wait for audio data to be available
        DWORD waitResult = WaitForSingleObject(hEvent, INFINITE);
        if (waitResult != WAIT_OBJECT_0) {
            if (isCapturing.load() && exitCallback) {
                snprintf(errorMsg, sizeof(errorMsg)-1, "Error waiting for audio data: %lu", GetLastError());
                exitCallback(errorMsg, context);
            }
            break;
        }
        
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
            // Get the available data
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
            
            // Skip silent packets
            if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) == 0 && numFramesInPacket > 0) {
                // Process audio data - copy from source format
                float* audioData = reinterpret_cast<float*>(buffer);
                size_t numSamples = numFramesInPacket * format->nChannels;
                
                audioBufferOriginal.resize(numSamples);
                std::memcpy(audioBufferOriginal.data(), audioData, numSamples * sizeof(float));
                
                // Convert to mono if needed
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
                
                // Resample if needed
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
                    // No resampling needed
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

void AudioCaptureImpl::stop(
    StopCaptureCallback stopCallback,
    void* context
) {
    // Set flag to stop capture thread
    isCapturing.store(false);
    
    // Signal event to wake up thread
    if (hEvent) {
        SetEvent(hEvent);
    }
    
    // Wait for thread to finish
    if (captureThread && captureThread->joinable()) {
        captureThread->join();
        delete captureThread;
        captureThread = nullptr;
    }
    
    // Stop audio client
    if (audioClient) {
        audioClient->Stop();
    }
    
    // Clean up resources
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
    
    // Clear buffers
    audioBufferOriginal.clear();
    audioBufferConverted.clear();
    audioBufferResampled.clear();
    
    // Call callback
    if (stopCallback) {
        stopCallback(context);
    }
}