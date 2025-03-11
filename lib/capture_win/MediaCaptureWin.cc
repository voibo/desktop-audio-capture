#include "MediaCaptureWin.h"
#include "capture/capture.h"
#include <cstring>
#include <sstream>
#include <chrono>
#include <vector>
#include <algorithm>
#include <memory>
#include <iostream>

// Windows-specific includes
#include <Windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <Functiondiscoverykeys_devpkey.h>
#include <dxgi.h>
#include <dxgi1_2.h>
#include <d3d11.h>
#include <atlbase.h>
#include <Mmsystem.h>
#include <propvarutil.h>
#include <VersionHelpers.h>
#include <Dwmapi.h>
#include <comdef.h>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "dwmapi.lib")

// Helper macros
#define HR_CHECK(hr, message) \
    if (FAILED(hr)) { \
        std::stringstream ss; \
        ss << message << " - HRESULT: 0x" << std::hex << hr; \
        std::cerr << ss.str() << std::endl; \
        snprintf(errorMessage, sizeof(errorMessage), "%s", ss.str().c_str()); \
        return false; \
    }

// Structure to hold display information
struct DisplayDeviceInfo {
    uint32_t displayID;
    std::wstring name;
    RECT bounds;
};

// Structure to hold window information
struct WinWindowInfo {
    uintptr_t windowID;  // uint32_tからuintptr_tに変更
    std::wstring title;
    std::wstring appName;
    HWND hwnd;
    RECT bounds;
};

// Global COM initialization
class ComInitializer {
public:
    ComInitializer() : initialized(false) {
        HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
        initialized = SUCCEEDED(hr);
    }
    
    ~ComInitializer() {
        if (initialized) {
            CoUninitialize();
        }
    }
    
    bool isInitialized() const { return initialized; }
    
private:
    bool initialized;
};

// C interface exports that implement capture.h MediaCapture functions
extern "C" {

void enumerateMediaCaptureTargets(int32_t type, EnumerateMediaCaptureTargetsCallback callback, void* context) {
    MediaCaptureWin::enumerateTargets(type, callback, context);
}

void* createMediaCapture(void) {
    return new MediaCaptureWin();
}

void destroyMediaCapture(void* p) {
    delete static_cast<MediaCaptureWin*>(p);
}

void startMediaCapture(void* p, MediaCaptureConfigC config, 
                       MediaCaptureDataCallback videoCallback,
                       MediaCaptureAudioDataCallback audioCallback, 
                       MediaCaptureExitCallback exitCallback, 
                       void* context) {
    auto* capture = static_cast<MediaCaptureWin*>(p);
    if (!capture->startCapture(config, videoCallback, audioCallback, exitCallback, context)) {
        std::string error = "Failed to start media capture";
        if (strlen(capture->getErrorMessage()) > 0) {
            error = capture->getErrorMessage();
        }
        char tempBuffer[1024];
        strcpy(tempBuffer, error.c_str());
        exitCallback(tempBuffer, context);  // callbackContextをcontextに変更
    }
}

void stopMediaCapture(void* p, StopCaptureCallback callback, void* context) {
    auto* capture = static_cast<MediaCaptureWin*>(p);
    capture->stopCapture(callback, context);
}

} // extern "C"

// Helper functions
namespace {
    // Convert wide string to UTF8
    std::string WideToUTF8(const std::wstring& wstr) {
        if (wstr.empty()) return "";
        int size_needed = WideCharToMultiByte(CP_UTF8, 0, wstr.c_str(), (int)wstr.size(), nullptr, 0, nullptr, nullptr);
        std::string strTo(size_needed, 0);
        WideCharToMultiByte(CP_UTF8, 0, wstr.c_str(), (int)wstr.size(), &strTo[0], size_needed, nullptr, nullptr);
        return strTo;
    }

    // Get process name from HWND
    std::wstring GetProcessNameFromHwnd(HWND hwnd) {
        DWORD pid;
        GetWindowThreadProcessId(hwnd, &pid);
        
        HANDLE hProcess = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
        if (!hProcess) return L"";
        
        WCHAR szProcessPath[MAX_PATH];
        DWORD dwSize = MAX_PATH;
        if (!QueryFullProcessImageNameW(hProcess, 0, szProcessPath, &dwSize)) {
            CloseHandle(hProcess);
            return L"";
        }
        
        CloseHandle(hProcess);
        
        // Extract filename from path
        WCHAR* pszFileName = wcsrchr(szProcessPath, L'\\');
        return (pszFileName) ? std::wstring(pszFileName + 1) : std::wstring(szProcessPath);
    }

    // Enumerate display devices
    std::vector<DisplayDeviceInfo> EnumerateDisplays() {
        std::vector<DisplayDeviceInfo> displays;
        DISPLAY_DEVICEW dispDevice;
        ZeroMemory(&dispDevice, sizeof(dispDevice));
        dispDevice.cb = sizeof(dispDevice);
        
        uint32_t displayID = 1; // Start from 1 to match macOS convention
        for (DWORD deviceIndex = 0; EnumDisplayDevicesW(nullptr, deviceIndex, &dispDevice, 0); deviceIndex++) {
            if ((dispDevice.StateFlags & DISPLAY_DEVICE_ACTIVE) && 
                (dispDevice.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP)) {
                
                DEVMODEW devMode;
                ZeroMemory(&devMode, sizeof(devMode));
                devMode.dmSize = sizeof(devMode);
                
                if (EnumDisplaySettingsW(dispDevice.DeviceName, ENUM_CURRENT_SETTINGS, &devMode)) {
                    DisplayDeviceInfo displayInfo;
                    displayInfo.displayID = displayID++;
                    displayInfo.name = dispDevice.DeviceName;
                    displayInfo.bounds.left = devMode.dmPosition.x;
                    displayInfo.bounds.top = devMode.dmPosition.y;
                    displayInfo.bounds.right = devMode.dmPosition.x + devMode.dmPelsWidth;
                    displayInfo.bounds.bottom = devMode.dmPosition.y + devMode.dmPelsHeight;
                    
                    displays.push_back(displayInfo);
                }
            }
        }
        
        return displays;
    }

    // Window enumeration callback
    BOOL CALLBACK EnumWindowsProc(HWND hwnd, LPARAM lParam) {
        std::vector<WinWindowInfo>* windows = reinterpret_cast<std::vector<WinWindowInfo>*>(lParam);
        
        if (!IsWindowVisible(hwnd)) return TRUE;
        
        WCHAR title[256];
        if (GetWindowTextW(hwnd, title, 256) == 0) return TRUE;
        
        // Skip windows with empty titles
        if (wcslen(title) == 0) return TRUE;
        
        // Skip system windows
        DWORD styles = GetWindowLong(hwnd, GWL_STYLE);
        DWORD exStyles = GetWindowLong(hwnd, GWL_EXSTYLE);
        if ((styles & WS_CHILD) || (exStyles & WS_EX_TOOLWINDOW)) return TRUE;
        
        // Get window bounds
        RECT bounds;
        if (!GetWindowRect(hwnd, &bounds)) return TRUE;
        
        // Skip windows with zero dimensions
        if (bounds.right - bounds.left <= 0 || bounds.bottom - bounds.top <= 0) return TRUE;
        
        // Get process name
        std::wstring processName = GetProcessNameFromHwnd(hwnd);
        
        WinWindowInfo windowInfo;
        windowInfo.windowID = reinterpret_cast<uintptr_t>(hwnd); // Use HWND as ID
        windowInfo.title = title;
        windowInfo.appName = processName;
        windowInfo.hwnd = hwnd;
        windowInfo.bounds = bounds;
        
        windows->push_back(windowInfo);
        return TRUE;
    }

    // Enumerate windows
    std::vector<WinWindowInfo> EnumerateWindows() {
        std::vector<WinWindowInfo> windows;
        EnumWindows(EnumWindowsProc, reinterpret_cast<LPARAM>(&windows));
        return windows;
    }
    
    // Create screenshot using Desktop Duplication API
    bool CaptureScreen(ID3D11Device* device, ID3D11DeviceContext* context, 
                       IDXGIOutputDuplication* duplication, 
                       uint8_t** pOutputBuffer, UINT* pOutputWidth, UINT* pOutputHeight, UINT* pBytesPerRow) {
        IDXGIResource* desktopResource = nullptr;
        DXGI_OUTDUPL_FRAME_INFO frameInfo;
        
        // Get the next frame
        HRESULT hr = duplication->AcquireNextFrame(500, &frameInfo, &desktopResource);
        if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
            return false;
        } else if (FAILED(hr)) {
            std::cerr << "Failed to acquire next frame: 0x" << std::hex << hr << std::endl;
            return false;
        }
        
        // Get the desktop texture
        ID3D11Texture2D* desktopTexture = nullptr;
        hr = desktopResource->QueryInterface(__uuidof(ID3D11Texture2D), reinterpret_cast<void**>(&desktopTexture));
        desktopResource->Release();
        
        if (FAILED(hr)) {
            std::cerr << "Failed to get desktop texture: 0x" << std::hex << hr << std::endl;
            duplication->ReleaseFrame();
            return false;
        }
        
        // Get texture description
        D3D11_TEXTURE2D_DESC textureDesc;
        desktopTexture->GetDesc(&textureDesc);
        
        // Create a staging texture for CPU access
        D3D11_TEXTURE2D_DESC stagingDesc = textureDesc;
        stagingDesc.Usage = D3D11_USAGE_STAGING;
        stagingDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        stagingDesc.BindFlags = 0;
        stagingDesc.MiscFlags = 0;
        stagingDesc.MipLevels = 1;
        
        ID3D11Texture2D* stagingTexture = nullptr;
        hr = device->CreateTexture2D(&stagingDesc, nullptr, &stagingTexture);
        if (FAILED(hr)) {
            std::cerr << "Failed to create staging texture: 0x" << std::hex << hr << std::endl;
            desktopTexture->Release();
            duplication->ReleaseFrame();
            return false;
        }
        
        // Copy the desktop texture to a staging texture
        context->CopyResource(stagingTexture, desktopTexture);
        
        // Map the texture to access the data
        D3D11_MAPPED_SUBRESOURCE mappedResource;
        hr = context->Map(stagingTexture, 0, D3D11_MAP_READ, 0, &mappedResource);
        if (FAILED(hr)) {
            std::cerr << "Failed to map staging texture: 0x" << std::hex << hr << std::endl;
            stagingTexture->Release();
            desktopTexture->Release();
            duplication->ReleaseFrame();
            return false;
        }
        
        // Allocate output buffer
        *pOutputWidth = textureDesc.Width;
        *pOutputHeight = textureDesc.Height;
        *pBytesPerRow = mappedResource.RowPitch;
        
        // Create a buffer for output (BGRA format)
        *pOutputBuffer = new uint8_t[mappedResource.RowPitch * textureDesc.Height];
        
        // Copy the data
        uint8_t* pSrc = static_cast<uint8_t*>(mappedResource.pData);
        for (UINT i = 0; i < textureDesc.Height; i++) {
            memcpy(*pOutputBuffer + i * mappedResource.RowPitch, 
                   pSrc + i * mappedResource.RowPitch, 
                   mappedResource.RowPitch);
        }
        
        // Unmap the texture
        context->Unmap(stagingTexture, 0);
        
        // Release resources
        stagingTexture->Release();
        desktopTexture->Release();
        duplication->ReleaseFrame();
        
        return true;
    }
}

// MediaCaptureWin implementation
MediaCaptureWin::MediaCaptureWin() 
    : captureInProgress(false), 
      captureThread(nullptr),
      videoCallback(nullptr),
      audioCallback(nullptr),
      exitCallback(nullptr),
      callbackContext(nullptr) {
    memset(errorMessage, 0, sizeof(errorMessage));
}

MediaCaptureWin::~MediaCaptureWin() {
    // Ensure capture is stopped
    if (captureInProgress) {
        stopCapture(nullptr, nullptr);
    }
}

bool MediaCaptureWin::startCapture(MediaCaptureConfigC config, 
                                  MediaCaptureDataCallback videoCallback,
                                  MediaCaptureAudioDataCallback audioCallback, 
                                  MediaCaptureExitCallback exitCallback,
                                  void* context) {
    // Check if capture is already in progress
    if (captureInProgress) {
        strncpy(errorMessage, "Capture already in progress", sizeof(errorMessage));
        return false;
    }
    
    // Store configuration and callbacks
    this->config = config;
    this->videoCallback = videoCallback;
    this->audioCallback = audioCallback;
    this->exitCallback = exitCallback;
    this->callbackContext = context;
    
    // Validate target
    if (config.displayID == 0 && config.windowID == 0 && config.bundleID == nullptr) {
        strncpy(errorMessage, "No valid capture target specified", sizeof(errorMessage));
        return false;
    }
    
    // Find specified target
    if (!findCaptureTarget(config.displayID, config.windowID, config.bundleID)) {
        strncpy(errorMessage, "Specified capture target not found", sizeof(errorMessage));
        return false;
    }
    
    // Start capture thread
    captureInProgress = true;
    captureThread = new std::thread(&MediaCaptureWin::captureThreadWorker, this);
    
    return true;
}

void MediaCaptureWin::stopCapture(StopCaptureCallback callback, void* context) {
    if (!captureInProgress) {
        if (callback) {
            callback(context);
        }
        return;
    }
    
    // Signal thread to stop
    {
        std::lock_guard<std::mutex> lock(captureMutex);
        captureInProgress = false;
        captureCV.notify_all();
    }
    
    // Wait for thread to join
    if (captureThread && captureThread->joinable()) {
        captureThread->join();
        delete captureThread;
        captureThread = nullptr;
    }
    
    // Clean up resources
    cleanupCapture();
    
    // Call callback
    if (callback) {
        callback(context);
    }
}

const char* MediaCaptureWin::getErrorMessage() const {
    return errorMessage;
}

void MediaCaptureWin::captureThreadWorker() {
    ComInitializer comInit;
    if (!comInit.isInitialized()) {
        if (exitCallback) {
            exitCallback("Failed to initialize COM", callbackContext);
        }
        captureInProgress = false;
        return;
    }
    
    // Initialize capture resources
    if (!initializeCapture()) {
        if (exitCallback) {
            exitCallback(errorMessage, callbackContext);
        }
        captureInProgress = false;
        return;
    }
    
    // Capture state
    CComPtr<ID3D11Device> d3dDevice;
    CComPtr<ID3D11DeviceContext> d3dContext;
    CComPtr<IDXGIOutput1> dxgiOutput;
    CComPtr<IDXGIOutputDuplication> duplication;
    DWORD targetSessionId = 0;
    
    // Initialize Direct3D
    D3D_FEATURE_LEVEL featureLevel;
    HRESULT hr = D3D11CreateDevice(
        nullptr,
        D3D_DRIVER_TYPE_HARDWARE,
        nullptr,
        0,
        nullptr,
        0,
        D3D11_SDK_VERSION,
        &d3dDevice,
        &featureLevel,
        &d3dContext
    );
    
    if (FAILED(hr)) {
        std::string error = "Failed to create D3D11 device: 0x" + std::to_string(hr);
        if (exitCallback) {
            char tempBuffer[1024];
            strcpy(tempBuffer, error.c_str());
            exitCallback(tempBuffer, callbackContext);
        }
        captureInProgress = false;
        return;
    }
    
    // Get DXGI device
    CComPtr<IDXGIDevice> dxgiDevice;
    hr = d3dDevice->QueryInterface(__uuidof(IDXGIDevice), reinterpret_cast<void**>(&dxgiDevice));
    if (FAILED(hr)) {
        std::string error = "Failed to get DXGI device: 0x" + std::to_string(hr);
        if (exitCallback) {
            char tempBuffer[1024];
            strcpy(tempBuffer, error.c_str());
            exitCallback(tempBuffer, callbackContext);
        }
        captureInProgress = false;
        return;
    }
    
    // Get DXGI adapter
    CComPtr<IDXGIAdapter> dxgiAdapter;
    hr = dxgiDevice->GetAdapter(&dxgiAdapter);
    if (FAILED(hr)) {
        std::string error = "Failed to get DXGI adapter: 0x" + std::to_string(hr);
        if (exitCallback) {
            char tempBuffer[1024];
            strcpy(tempBuffer, error.c_str());
            exitCallback(tempBuffer, callbackContext);
        }
        captureInProgress = false;
        return;
    }
    
    // Find the output matching the target display
    bool foundOutput = false;
    for (UINT i = 0; !foundOutput; i++) {
        CComPtr<IDXGIOutput> output;
        hr = dxgiAdapter->EnumOutputs(i, &output);
        if (hr == DXGI_ERROR_NOT_FOUND) {
            break;
        }
        
        DXGI_OUTPUT_DESC outputDesc;
        hr = output->GetDesc(&outputDesc);
        if (FAILED(hr)) {
            continue;
        }
        
        // For display capture, check display ID
        if (config.displayID > 0) {
            // Map the monitor to a display device
            DISPLAY_DEVICEW displayDevice;
            ZeroMemory(&displayDevice, sizeof(displayDevice));
            displayDevice.cb = sizeof(displayDevice);
            
            for (DWORD j = 0; EnumDisplayDevicesW(NULL, j, &displayDevice, 0); j++) {
                DEVMODEW devMode;
                ZeroMemory(&devMode, sizeof(devMode));
                devMode.dmSize = sizeof(devMode);
                
                if (EnumDisplaySettingsW(displayDevice.DeviceName, ENUM_CURRENT_SETTINGS, &devMode)) {
                    RECT displayBounds = {
                        devMode.dmPosition.x,
                        devMode.dmPosition.y,
                        devMode.dmPosition.x + (LONG)devMode.dmPelsWidth,
                        devMode.dmPosition.y + (LONG)devMode.dmPelsHeight
                    };
                    
                    // Check if this is the target display
                    if (outputDesc.DesktopCoordinates.left == displayBounds.left &&
                        outputDesc.DesktopCoordinates.top == displayBounds.top &&
                        outputDesc.DesktopCoordinates.right == displayBounds.right &&
                        outputDesc.DesktopCoordinates.bottom == displayBounds.bottom) {
                        
                        // Found the output for the target display
                        CComPtr<IDXGIOutput1> output1;
                        hr = output->QueryInterface(__uuidof(IDXGIOutput1), reinterpret_cast<void**>(&output1));
                        if (SUCCEEDED(hr)) {
                            dxgiOutput = output1;
                            foundOutput = true;
                            break;
                        }
                    }
                }
            }
        }
        // For window capture, check if the window is on this output
        else if (config.windowID > 0) {
            // 64bit Windows環境でHWNDとuint32_t間の変換警告を回避するためのキャスト
            HWND hwnd = reinterpret_cast<HWND>(static_cast<uintptr_t>(config.windowID));
            RECT windowRect;
            if (GetWindowRect(hwnd, &windowRect)) {
                RECT intersection;
                if (IntersectRect(&intersection, &windowRect, &outputDesc.DesktopCoordinates)) {
                    // Window is on this output
                    CComPtr<IDXGIOutput1> output1;
                    hr = output->QueryInterface(__uuidof(IDXGIOutput1), reinterpret_cast<void**>(&output1));
                    if (SUCCEEDED(hr)) {
                        dxgiOutput = output1;
                        foundOutput = true;
                        break;
                    }
                }
            }
        }
    }
    
    if (!foundOutput) {
        std::string error = "Failed to find the target display or window";
        if (exitCallback) {
            char tempBuffer[1024];
            strcpy(tempBuffer, error.c_str());
            exitCallback(tempBuffer, callbackContext);
        }
        captureInProgress = false;
        return;
    }
    
    // Create desktop duplication
    hr = dxgiOutput->DuplicateOutput(d3dDevice, &duplication);
    if (FAILED(hr)) {
        std::string error = "Failed to create desktop duplication: 0x" + std::to_string(hr);
        if (exitCallback) {
            char tempBuffer[1024];
            strcpy(tempBuffer, error.c_str());
            exitCallback(tempBuffer, callbackContext);
        }
        captureInProgress = false;
        return;
    }
    
    // Audio capture setup
    CComPtr<IMMDeviceEnumerator> deviceEnumerator;
    hr = CoCreateInstance(
        __uuidof(MMDeviceEnumerator),
        nullptr,
        CLSCTX_ALL,
        __uuidof(IMMDeviceEnumerator),
        reinterpret_cast<void**>(&deviceEnumerator)
    );
    
    if (FAILED(hr)) {
        std::string error = "Failed to create device enumerator: 0x" + std::to_string(hr);
        if (exitCallback) {
            char tempBuffer[1024];
            strcpy(tempBuffer, error.c_str());
            exitCallback(tempBuffer, callbackContext);
        }
        captureInProgress = false;
        return;
    }
    
    // Get the default audio render endpoint
    CComPtr<IMMDevice> audioDevice;
    hr = deviceEnumerator->GetDefaultAudioEndpoint(eRender, eConsole, &audioDevice);
    if (FAILED(hr)) {
        std::string error = "Failed to get default audio endpoint: 0x" + std::to_string(hr);
        if (exitCallback) {
            char tempBuffer[1024];
            strcpy(tempBuffer, error.c_str());
            exitCallback(tempBuffer, callbackContext);
        }
        captureInProgress = false;
        return;
    }
    
    // Activate the IAudioClient interface
    CComPtr<IAudioClient> audioClient;
    hr = audioDevice->Activate(
        __uuidof(IAudioClient),
        CLSCTX_ALL,
        nullptr,
        reinterpret_cast<void**>(&audioClient)
    );
    
    if (FAILED(hr)) {
        std::string error = "Failed to activate audio client: 0x" + std::to_string(hr);
        if (exitCallback) {
            char tempBuffer[1024];
            strcpy(tempBuffer, error.c_str());
            exitCallback(tempBuffer, callbackContext);
        }
        captureInProgress = false;
        return;
    }
    
    // Get the audio format
    WAVEFORMATEX* pwfx = nullptr;
    hr = audioClient->GetMixFormat(&pwfx);
    if (FAILED(hr)) {
        std::string error = "Failed to get audio mix format: 0x" + std::to_string(hr);
        if (exitCallback) {
            char tempBuffer[1024];
            strcpy(tempBuffer, error.c_str());
            exitCallback(tempBuffer, callbackContext);
        }
        captureInProgress = false;
        return;
    }
    
    // Adjust the format if needed
    if (config.audioChannels > 0) {
        pwfx->nChannels = static_cast<WORD>(config.audioChannels);
    }
    
    if (config.audioSampleRate > 0) {
        pwfx->nSamplesPerSec = static_cast<DWORD>(config.audioSampleRate);
    }
    
    // Update derived values
    pwfx->nBlockAlign = pwfx->nChannels * pwfx->wBitsPerSample / 8;
    pwfx->nAvgBytesPerSec = pwfx->nSamplesPerSec * pwfx->nBlockAlign;
    
    // Initialize the audio client
    hr = audioClient->Initialize(
        AUDCLNT_SHAREMODE_SHARED,
        AUDCLNT_STREAMFLAGS_LOOPBACK,
        0,
        0,
        pwfx,
        nullptr
    );
    
    if (FAILED(hr)) {
        CoTaskMemFree(pwfx);
        std::string error = "Failed to initialize audio client: 0x" + std::to_string(hr);
        if (exitCallback) {
            char tempBuffer[1024];
            strcpy(tempBuffer, error.c_str());
            exitCallback(tempBuffer, callbackContext);
        }
        captureInProgress = false;
        return;
    }
    
    // Get the capture client
    CComPtr<IAudioCaptureClient> audioCaptureClient;
    hr = audioClient->GetService(
        __uuidof(IAudioCaptureClient),
        reinterpret_cast<void**>(&audioCaptureClient)
    );
    
    if (FAILED(hr)) {
        CoTaskMemFree(pwfx);
        std::string error = "Failed to get audio capture client: 0x" + std::to_string(hr);
        if (exitCallback) {
            char tempBuffer[1024];
            strcpy(tempBuffer, error.c_str());
            exitCallback(tempBuffer, callbackContext);
        }
        captureInProgress = false;
        return;
    }
    
    // Start the audio client
    hr = audioClient->Start();
    if (FAILED(hr)) {
        CoTaskMemFree(pwfx);
        std::string error = "Failed to start audio client: 0x" + std::to_string(hr);
        if (exitCallback) {
            char tempBuffer[1024];
            strcpy(tempBuffer, error.c_str());
            exitCallback(tempBuffer, callbackContext);
        }
        captureInProgress = false;
        return;
    }
    
    // Main capture loop
    std::chrono::steady_clock::time_point lastFrameTime = std::chrono::steady_clock::now();
    float frameInterval = 1.0f / (config.frameRate > 0 ? config.frameRate : 30.0f);
    
    while (captureInProgress) {
        std::unique_lock<std::mutex> lock(captureMutex);
        
        // Process audio
        UINT32 packetLength = 0;
        hr = audioCaptureClient->GetNextPacketSize(&packetLength);
        if (SUCCEEDED(hr) && packetLength > 0) {
            BYTE* pData;
            UINT32 numFramesAvailable;
            DWORD flags;
            UINT64 devicePosition;
            UINT64 qpcPosition;
            
            hr = audioCaptureClient->GetBuffer(
                &pData,
                &numFramesAvailable,
                &flags,
                &devicePosition,
                &qpcPosition
            );
            
            if (SUCCEEDED(hr)) {
                // Process audio data
                if (audioCallback && numFramesAvailable > 0) {
                    // Convert to float format if needed
                    if (pwfx->wFormatTag == WAVE_FORMAT_IEEE_FLOAT || 
                        (pwfx->wFormatTag == WAVE_FORMAT_EXTENSIBLE && 
                         reinterpret_cast<WAVEFORMATEXTENSIBLE*>(pwfx)->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT)) {
                        
                        // Data is already in float format
                        float* pFloatData = reinterpret_cast<float*>(pData);
                        
                        // Process the audio data
                        processAudioData(pwfx->nChannels, pwfx->nSamplesPerSec, pFloatData, numFramesAvailable);
                    }
                    else {
                        // Convert from integer format to float
                        size_t bytesPerSample = pwfx->wBitsPerSample / 8;
                        size_t totalSamples = numFramesAvailable * pwfx->nChannels;
                        std::vector<float> floatData(totalSamples);
                        
                        // Convert based on format
                        if (pwfx->wBitsPerSample == 16) {
                            int16_t* pIntData = reinterpret_cast<int16_t*>(pData);
                            for (size_t i = 0; i < totalSamples; i++) {
                                floatData[i] = pIntData[i] / 32768.0f;
                            }
                        }
                        else if (pwfx->wBitsPerSample == 32 && pwfx->wFormatTag != WAVE_FORMAT_IEEE_FLOAT) {
                            int32_t* pIntData = reinterpret_cast<int32_t*>(pData);
                            for (size_t i = 0; i < totalSamples; i++) {
                                floatData[i] = pIntData[i] / 2147483648.0f;
                            }
                        }
                        
                        // Process the audio data
                        processAudioData(pwfx->nChannels, pwfx->nSamplesPerSec, floatData.data(), numFramesAvailable);
                    }
                }
                
                // Release the buffer
                audioCaptureClient->ReleaseBuffer(numFramesAvailable);
            }
        }
        
        // Check if it's time to capture a new video frame
        auto now = std::chrono::steady_clock::now();
        float elapsedSec = std::chrono::duration<float>(now - lastFrameTime).count();
        
        if (elapsedSec >= frameInterval) {
            lastFrameTime = now;
            
            // Capture screen
            uint8_t* frameBuffer = nullptr;
            UINT width = 0, height = 0, bytesPerRow = 0;
            
            if (CaptureScreen(d3dDevice, d3dContext, duplication, &frameBuffer, &width, &height, &bytesPerRow)) {
                // Process captured frame
                if (videoCallback) {
                    int32_t timestamp = static_cast<int32_t>(
                        std::chrono::duration_cast<std::chrono::milliseconds>(
                            std::chrono::system_clock::now().time_since_epoch()
                        ).count()
                    );
                    
                    // Call the video callback
                    videoCallback(
                        frameBuffer, 
                        width, 
                        height, 
                        bytesPerRow, 
                        timestamp,
                        "bgra", 
                        height * bytesPerRow, 
                        callbackContext
                    );
                }
                
                // Clean up
                delete[] frameBuffer;
            }
        }
        
        // Wait for a short period or until signaled to stop
        captureCV.wait_for(lock, std::chrono::milliseconds(10));
    }
    
    // Stop audio client
    if (audioClient) {
        audioClient->Stop();
    }
    
    // Free audio format
    CoTaskMemFree(pwfx);
}

bool MediaCaptureWin::initializeCapture() {
    // Initialize COM
    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    HR_CHECK(hr, "Failed to initialize COM");
    
    return true;
}

void MediaCaptureWin::cleanupCapture() {
    // Uninitialize COM
    CoUninitialize();
}

bool MediaCaptureWin::findCaptureTarget(uint32_t displayID, uint32_t windowID, const char* bundleID) {
    ComInitializer comInit;
    if (!comInit.isInitialized()) {
        strncpy(errorMessage, "Failed to initialize COM for target search", sizeof(errorMessage));
        return false;
    }
    
    if (displayID > 0) {
        // Find display by ID
        auto displays = EnumerateDisplays();
        for (const auto& display : displays) {
            if (display.displayID == displayID) {
                return true;
            }
        }
        
        snprintf(errorMessage, sizeof(errorMessage), "Display with ID %u not found", displayID);
        return false;
    }
    else if (windowID > 0) {
        // Find window by ID (HWND)
        HWND hwnd = reinterpret_cast<HWND>(static_cast<uintptr_t>(windowID));
        if (!IsWindow(hwnd)) {
            snprintf(errorMessage, sizeof(errorMessage), "Window with ID %u not found", windowID);
            return false;
        }
        return true;
    }
    else if (bundleID != nullptr) {
        // Find window by process name
        std::string processNameToFind(bundleID);
        auto windows = EnumerateWindows();
        
        for (const auto& window : windows) {
            std::string appName = WideToUTF8(window.appName);
            // Case-insensitive search
            std::string lowerAppName = appName;
            std::string lowerProcessName = processNameToFind;
            std::transform(lowerAppName.begin(), lowerAppName.end(), lowerAppName.begin(), ::tolower);
            std::transform(lowerProcessName.begin(), lowerProcessName.end(), lowerProcessName.begin(), ::tolower);
            
            if (lowerAppName.find(lowerProcessName) != std::string::npos) {
                // Set the windowID in the config
                config.windowID = reinterpret_cast<uintptr_t>(window.hwnd);
                return true;
            }
        }
        
        snprintf(errorMessage, sizeof(errorMessage), "Window with process name '%s' not found", bundleID);
        return false;
    }
    
    return false;
}

void MediaCaptureWin::processAudioData(int32_t channels, int32_t sampleRate, float* data, int32_t frameCount) {
    if (!audioCallback) {
        return;
    }
    
    // Call the audio callback
    audioCallback(channels, sampleRate, data, frameCount, callbackContext);
}

void MediaCaptureWin::enumerateTargets(int32_t type, EnumerateMediaCaptureTargetsCallback callback, void* context) {
    // Initialize COM
    ComInitializer comInit;
    if (!comInit.isInitialized()) {
        callback(nullptr, 0, "Failed to initialize COM", context);
        return;
    }
    
    std::vector<MediaCaptureTargetC> targets;
    
    // Get displays
    if (type == 0 || type == 1) { // ALL or DISPLAY
        auto displays = EnumerateDisplays();
        
        for (const auto& display : displays) {
            MediaCaptureTargetC target = {};
            target.isDisplay = 1;
            target.isWindow = 0;
            target.displayID = display.displayID;
            target.windowID = 0;
            target.width = display.bounds.right - display.bounds.left;
            target.height = display.bounds.bottom - display.bounds.top;
            
            std::string displayName = "Display " + std::to_string(display.displayID);
            target.title = _strdup(displayName.c_str());
            target.appName = nullptr;
            
            targets.push_back(target);
        }
    }
    
    // Get windows
    if (type == 0 || type == 2) { // ALL or WINDOW
        auto windows = EnumerateWindows();
        
        for (const auto& window : windows) {
            MediaCaptureTargetC target = {};
            target.isDisplay = 0;
            target.isWindow = 1;
            target.displayID = 0;
            target.windowID = window.windowID;
            target.width = window.bounds.right - window.bounds.left;
            target.height = window.bounds.bottom - window.bounds.top;
            
            std::string title = WideToUTF8(window.title);
            std::string appName = WideToUTF8(window.appName);
            
            target.title = _strdup(title.c_str());
            target.appName = _strdup(appName.c_str());
            
            targets.push_back(target);
        }
    }
    
    // Call the callback with the targets
    if (targets.empty()) {
        callback(nullptr, 0, nullptr, context);
    } else {
        callback(targets.data(), static_cast<int32_t>(targets.size()), nullptr, context);
        
        // Clean up allocated strings
        for (auto& target : targets) {
            if (target.title) free(target.title);
            if (target.appName) free(target.appName);
        }
    }
}