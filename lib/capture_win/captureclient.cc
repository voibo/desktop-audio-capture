#include "captureclient.h"
#include <stdio.h>
#include <inttypes.h>
#include <functional>

// see https://learn.microsoft.com/en-us/windows/win32/coreaudio/capturing-a-stream
// https://github.com/microsoft/Windows-classic-samples/blob/main/Samples/ApplicationLoopback/cpp/LoopbackCapture.cpp
// https://learn.microsoft.com/en-us/answers/questions/786447/recording-desktop-audio?orderBy=Helpful
// https://github.com/microsoft/windows-classic-samples/tree/main/Samples/ApplicationLoopback#application-loopback-api-capture-sample

void AudioCaptureClient::initializeCom() {
    hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    assert(SUCCEEDED(hr));
}

void AudioCaptureClient::uninitializeCom() {
    CoUninitialize();
    //std::cerr << "C++ uninitialized COM" << std::endl;
}

/* for debugging

std::string ToString(GUID *guid) {
    char guid_string[37]; // 32 hex chars + 4 hyphens + null terminator
    snprintf(
          guid_string, sizeof(guid_string),
          "%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x",
          guid->Data1, guid->Data2, guid->Data3,
          guid->Data4[0], guid->Data4[1], guid->Data4[2],
          guid->Data4[3], guid->Data4[4], guid->Data4[5],
          guid->Data4[6], guid->Data4[7]);
    return guid_string;
}
*/

void AudioCaptureClient::audioRetrievalThreadWorker(
  StartCaptureDataCallback dataCallback,
  StartCaptureExitCallback exitCallback,
  void* context
) {
  while(captureInProgress) {
    DWORD retval = WaitForSingleObject(hEvent, INFINITE);
    retrieveAndResampleAllPendingOriginalAudio();

    // dataCallback(config.channels, config.sampleRate, UnsafePointer(floatData[0]), Int32(outputBuffer.frameLength), context)

    // see AudioCapture::StartCaptureDataCallback().
    // there, the data buffer is copied (in the same thread), then the copy of the
    // data buffer processed a separate thread by the JS callback function.
    // therefore, there is no need to use a C++ mutex to protect threaded access
    // to the data buffer.
    dataCallback(this->cc.channels, this->cc.sampleRate, &resampledMonoAudio[0], resampledMonoAudio.size(), context);
  }
}

void AudioCaptureClient::startCapture(
  CaptureConfig cc,
  StartCaptureDataCallback dataCallback, 
  StartCaptureExitCallback exitCallback, // FIXME: instead of assert, use exitCallback
  void *context
) {
    errorMessage[1023] = 0;

    // CaptureConfig cc represents the final desired output format of the audio.
    this->cc = cc;
    
    // For the output audio channels, currently only 1 channel (not 2 channel stereo) is supported,
    // and the native 2-channel Windows captured audio is merged into 1 channel.
    if(cc.channels != 1) {
        snprintf(errorMessage, 1023, "unsupported value %d of cc.channels, only 1 channel supported", cc.channels);
        exitCallback(errorMessage, context);
        return;
    }

    // For the output sample rate, a resampler will change the native Windows audio data to the
    // desired output sample rate.
    int error;
    sampleRateConverter = src_new(SRC_SINC_BEST_QUALITY, 1, &error);
    if (sampleRateConverter == NULL) {
        std::cerr << "ERROR: could not create sampleRateConverter, error code: " << error << std::endl;
    }
    else {
        std::cerr << "created sampleRateConverter success" << std::endl;
    }

    // see https://stackoverflow.com/questions/12844431/linking-wasapi-in-vs-2010
    // for some reason using CLSID_MMDeviceEnumerator and IID_IMMDeviceEnumerator
    // leads to link error when compiling with MS visual studio. instead we have to
    // use __uuidof(xxx) as below to fix the link eror.
    hr = CoCreateInstance(
        __uuidof(MMDeviceEnumerator), /* CLSID_MMDeviceEnumerator, */
        NULL,
        CLSCTX_ALL,
        __uuidof(IMMDeviceEnumerator), /* IID_IMMDeviceEnumerator, */
        (void**)&enumerator
    );

    if(!SUCCEEDED(hr)) {
        snprintf(errorMessage, 1023, "error initializing desktop audio capture at CoCreateInstance");
        exitCallback(errorMessage, context);
        return;
    }

    hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &recorder);
    if(!SUCCEEDED(hr)) {
        snprintf(errorMessage, 1023,  "error initializing desktop audio capture at GetDefaultAudioEndpoint");
        exitCallback(errorMessage, context);
        return;
    }

    hr = enumerator->Release();
    if(!SUCCEEDED(hr)) {
        snprintf(errorMessage, 1023,  "error initializing desktop audio capture at enumerator->Release");
        exitCallback(errorMessage, context);
        return;
    }

    hr = recorder->Activate(
        __uuidof(IAudioClient), /* IID_IAudioClient, */
        CLSCTX_ALL, NULL, (void**)&recorderClient);
    if(!SUCCEEDED(hr)) {
        snprintf(errorMessage, 1023, "error initializing desktop audio capture at recorder->Activate");
        exitCallback(errorMessage, context);
        return;
    }

    hr = recorderClient->GetMixFormat(&format);
    if(!SUCCEEDED(hr)) {
        snprintf(errorMessage, 1023, "error initializing desktop audio capture at recorderClient->GetMixFormat");
        exitCallback(errorMessage, context);
        return;
    }

    /*
    printf("Mix format:\n");
    printf("  Frame size     : %d\n", format->nBlockAlign);
    printf("  Channels       : %d\n", format->nChannels);
    printf("  Bits per second: %d\n", format->wBitsPerSample);
    printf("  Sample rate:   : %d\n", format->nSamplesPerSec);
    printf("  wFormatTag:   : %d\n", format->wFormatTag);
    printf("  cbSize:   : %d\n", format->cbSize);
    */

    // NOTE: for audio capture, format seems to be WAVE_FORMAT_EXTENSIBLE
    // and WAVEFORMATEXTENSIBLE.SubType is expected to be KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
    // see https://stackoverflow.com/questions/41876857/interpreting-waveformatextensible-from-iaudioclientgetmixformat
    // https://learn.microsoft.com/en-us/windows/win32/api/mmreg/ns-mmreg-waveformatextensible?redirectedfrom=MSDN
    // https://stackoverflow.com/questions/30692623/wasapi-loopback-save-wave-file

    // ensure original mix format is valid (4-byte floates)
    // and is stereo (2 channels). if not, then later code
    // will fail when merging 2 channels into 1 and when
    // doing resampling.

    bool formatIsValid =
     (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE)
     && IsEqualGUID(((WAVEFORMATEXTENSIBLE*)format)->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
    if(!formatIsValid) {
        snprintf(errorMessage, 1023, "error initializing desktop audio capture, desktop audio is not 4-byte floating point format");
        exitCallback(errorMessage, context);
        return;
    }

    if(format->nChannels != 2) {
        snprintf(errorMessage, 1023, "error initializing desktop audio capture, desktop audio is not 2-channel stereo");
        exitCallback(errorMessage, context);
        return;
    }

    hr = recorderClient->Initialize(AUDCLNT_SHAREMODE_SHARED,  
      AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
      10000000, 
      0, 
      format, 
      NULL);
    if(!SUCCEEDED(hr)) {
        snprintf(errorMessage, 1023, "error initializing desktop audio capture at recorderClient->Initialize");
        exitCallback(errorMessage, context);
        return;
    }

    hr = recorderClient->GetService(
        __uuidof(IAudioCaptureClient), /* IID_IAudioCaptureClient, */
        (void**)&captureService);
    if(!SUCCEEDED(hr)) {
        snprintf(errorMessage, 1023, "error initializing desktop audio capture at recorderClient->GetService");
        exitCallback(errorMessage, context);
        return;
    }

    hEvent = CreateEvent(NULL, FALSE, FALSE, NULL);
    if(hEvent == NULL) {
        snprintf(errorMessage, 1023, "error initializing desktop audio capture at CreateEvent");
        exitCallback(errorMessage, context);
        return;
    }

    hr = recorderClient->SetEventHandle(hEvent);
    if(!SUCCEEDED(hr)) {
        snprintf(errorMessage, 1023, "error initializing desktop audio capture at recorderClient->SetEventHandle");
        exitCallback(errorMessage, context);
        return;
    }
 
    hr = recorderClient->Start();
    if(!SUCCEEDED(hr)) {
        snprintf(errorMessage, 1023, "error initializing desktop audio capture at recorderClient->Start");
        exitCallback(errorMessage, context);
        return;
    }

    captureInProgress = true;
    this->audioRetrievalThread = new std::thread(
      std::bind(&AudioCaptureClient::audioRetrievalThreadWorker, this, dataCallback, exitCallback, context)
    );
}


void AudioCaptureClient::retrieveAllPendingOriginalAudio() {
    originalStereoAudioAwaitingResampling.clear();

    UINT32 framesAvailable = 0;
    hr = captureService->GetNextPacketSize(&framesAvailable);
    // printf("C++: %d frames available\n", framesAvailable);
    assert(SUCCEEDED(hr));

    while (framesAvailable > 0) {
        // std::cerr << "NLIN: capturing " << framesAvailable << " frames" << std::endl;
        hr = captureService->GetBuffer(&captureBufferFromOS, &nFrames, &flags, NULL, NULL);
        assert(SUCCEEDED(hr));
        
        int capturedByteCount = nFrames * format->nBlockAlign;
        int capturedFloatCount = capturedByteCount / sizeof(float);

        originalStereoAudioAwaitingResampling.insert(
            originalStereoAudioAwaitingResampling.end(), 
            (float*)(captureBufferFromOS),
            (float*)(captureBufferFromOS) + capturedFloatCount
        );
        hr = captureService->ReleaseBuffer(nFrames);
        assert(SUCCEEDED(hr));
        hr = captureService->GetNextPacketSize(&framesAvailable);
        assert(SUCCEEDED(hr));
    }
    // std::cerr << "NLIN: done capturing frames because " << framesAvailable << " frames avail" << std::endl;
}

void AudioCaptureClient::resampleAllPendingOriginalAudio() {

    //std::cerr << "NLIN: enter resample function" << std::endl;
    int numAvailableFrames = originalStereoAudioAwaitingResampling.size() / 2; // divide by 2 because of 2 channels L/R in one frame
    //std::cerr << "NLIN: num available frames: " << numAvailableFrames << std::endl;

    float oldRate = format->nSamplesPerSec;
    float newRate = this->cc.sampleRate;
    float sampleRatio = newRate / oldRate;
    float requiredResampledFrames = numAvailableFrames * sampleRatio;
    resampledMonoAudio.clear();
    if (resampledMonoAudio.size() < requiredResampledFrames) {
        resampledMonoAudio.resize(requiredResampledFrames);
    }

    // convert stereo to mono
    originalMonoAudioAwaitingResampling.clear();
    if (originalMonoAudioAwaitingResampling.size() < originalStereoAudioAwaitingResampling.size() / 2) {
        originalMonoAudioAwaitingResampling.resize(originalStereoAudioAwaitingResampling.size() / 2);
    }

    int iFrame;
    for (iFrame = 0; iFrame < numAvailableFrames; iFrame++) {
        float monoSample = 0.5 * (originalStereoAudioAwaitingResampling[iFrame*2] + originalStereoAudioAwaitingResampling[iFrame*2 + 1]);
        originalMonoAudioAwaitingResampling[iFrame] = monoSample;
    }
    originalStereoAudioAwaitingResampling.clear();


    SRC_DATA data = {
        &originalMonoAudioAwaitingResampling[0],
        &resampledMonoAudio[0],
        (long)numAvailableFrames,
        (long)requiredResampledFrames,
        (long)0, // output parm: input_frames_used
        (long)0, // output parm: output_frames_gen
        (int)0, // output parm: end_of_input
        (double)sampleRatio
    };

    src_process(sampleRateConverter, &data);
    if (data.output_frames_gen != requiredResampledFrames) {
        resampledMonoAudio.resize(data.output_frames_gen);
        //std::cerr << "NLIN: ERR: done resampling, used " << data.input_frames_used << " of "
        //    << data.input_frames << " input frames to create " << data.output_frames_gen <<
        //    " output frames expecting " << requiredResampledFrames << std::endl;
    }
}



UINT32 AudioCaptureClient::retrieveAndResampleAllPendingOriginalAudio() {
    retrieveAllPendingOriginalAudio();
    resampleAllPendingOriginalAudio();
    return resampledMonoAudio.size();
}

void AudioCaptureClient::stopCapture(StopCaptureCallback stopCaptureCallback, void* context) {
    // signal to the worker thread to stop
    captureInProgress = false;

    // wait until worker thread exits
    if(audioRetrievalThread) {
      if(audioRetrievalThread->joinable()) {
        audioRetrievalThread->join();
      }
      delete audioRetrievalThread;
    }

    // delete the event handle used by the worker thread
    if (hEvent != NULL)
    {
        CloseHandle(hEvent);
    }

    recorderClient->Stop();
    captureService->Release();
    recorderClient->Release();
    recorder->Release();

    if (sampleRateConverter) {
        src_delete(sampleRateConverter);
    }

    stopCaptureCallback(context);
}