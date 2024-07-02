#include <stdio.h>
#include <Windows.h>
extern "C" {
#include <initguid.h>
#include <mmdeviceapi.h>
}
#include <Audioclient.h>

#include <assert.h>
#include <iostream>
#include <sstream>
#include <samplerate.h>
#include <vector>
#include <thread>
#include "capture/capture.h"

class AudioCaptureClient {
private:
    HRESULT hr;
    IMMDeviceEnumerator* enumerator = NULL;
    IMMDevice* recorder = NULL;
    IAudioClient* recorderClient = NULL;
    IAudioCaptureClient* captureService = NULL;
    WAVEFORMATEX* format = NULL;

    UINT32 nFrames;
    DWORD flags;
    BYTE* captureBufferFromOS; // a single audio capture buffer from OS. memory is allocated by OS, not from us

    SRC_STATE *sampleRateConverter = NULL;

    // all of the following buffers assume 4-byte floats
    std::vector<float> originalStereoAudioAwaitingResampling; // accumulated collection of all single audio capture buffers from OS, in original sample rate before resampling
    std::vector<float> originalMonoAudioAwaitingResampling;
    std::vector<float> resampledMonoAudio;
    void retrieveAllPendingOriginalAudio();
    void resampleAllPendingOriginalAudio();
    UINT32 retrieveAndResampleAllPendingOriginalAudio();
    void audioRetrievalThreadWorker(StartCaptureDataCallback dataCallback, StartCaptureExitCallback exitCallback, void *context);
    std::thread *audioRetrievalThread = NULL;
    bool captureInProgress = false;
    HANDLE hEvent = NULL;
    CaptureConfig cc;
    char errorMessage[1024];

public:
    void initializeCom();
    void uninitializeCom();
    void startCapture(CaptureConfig cc, StartCaptureDataCallback dataCallback, StartCaptureExitCallback exitCallback, void* context);
    void stopCapture(StopCaptureCallback stopCallback, void* context);
};