/**
 * @file mediacaptureclient.cc
 * @brief Windows implementation of media (audio and video) capture functionality
 */

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "psapi.lib")

#include <Windows.h>
#include <tchar.h>
#include <psapi.h>
#include "mediacaptureclient.h"
#include "audiocaptureimpl.h"
#include "videocaptureimpl.h"
#include <iostream>
#include <sstream>
#include <algorithm>
#include <cstring>
#include <functional>

/**
 * Default constructor - initializes audio capture
 */
MediaCaptureClient::MediaCaptureClient() : isCapturing(false) {
    audioImpl = std::make_unique<AudioCaptureImpl>();
}

/**
 * Destructor - ensures capture is stopped
 */
MediaCaptureClient::~MediaCaptureClient() {
    if (isCapturing.load()) {
        stopCapture(nullptr, nullptr);
    }
}

/**
 * Initialize COM library with multi-threaded model
 */
void MediaCaptureClient::initializeCom() {
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr) && hr != S_FALSE && hr != RPC_E_CHANGED_MODE) {
        std::stringstream ss;
        ss << "Failed to initialize COM: 0x" << std::hex << hr;
        setError(ss.str());
    }
}

/**
 * Clean up COM library
 */
void MediaCaptureClient::uninitializeCom() {
    CoUninitialize();
}

/**
 * Start capturing audio and/or video based on configuration
 */
bool MediaCaptureClient::startCapture(
    const MediaCaptureConfigC& config,
    MediaCaptureDataCallback videoCallback,
    MediaCaptureAudioDataCallback audioCallback,
    MediaCaptureExitCallback exitCallback,
    void* context
) {
    std::lock_guard<std::mutex> lock(captureMutex);
    
    fprintf(stderr, "DEBUG: MediaCaptureClient::startCapture called with isElectron=%d\n", config.isElectron);
    
    if (isCapturing.load()) {
        if (exitCallback) {
            exitCallback("Capture already in progress", context);
        }
        return false;
    }

    bool audioResult = true;
    bool videoResult = true;

    // Initialize audio capture if callback provided
    if (audioCallback) {
        fprintf(stderr, "DEBUG: Starting audio capture\n");
        audioImpl = std::make_unique<AudioCaptureImpl>();
        audioResult = audioImpl->start(config, audioCallback, exitCallback, context);
        fprintf(stderr, "DEBUG: Audio capture start result: %s\n", audioResult ? "success" : "failed");
    }

    // Initialize video capture if callback provided and valid target specified
    if (videoCallback && (config.displayID > 0 || config.windowID > 0)) {
        fprintf(stderr, "DEBUG: Starting video capture (displayID=%d, windowID=%d)\n", 
                config.displayID, config.windowID);
        try {
            videoImpl = std::make_unique<VideoCaptureImpl>();
            videoResult = videoImpl->start(config, videoCallback, exitCallback, context);
            fprintf(stderr, "DEBUG: Video capture start result: %s\n", videoResult ? "success" : "failed");
        }
        catch (const std::exception& e) {
            fprintf(stderr, "DEBUG: Exception in video capture: %s\n", e.what());
            videoResult = false;
            if (exitCallback) {
                char error[256];
                snprintf(error, sizeof(error), "Video capture exception: %s", e.what());
                exitCallback(error, context);
            }
        }
        catch (...) {
            fprintf(stderr, "DEBUG: Unknown exception in video capture\n");
            videoResult = false;
            if (exitCallback) {
                exitCallback("Unknown exception in video capture", context);
            }
        }
    }

    // Consider capture started if either audio or video succeeded
    if (audioResult || videoResult) {
        isCapturing.store(true);
        return true;
    }
    
    return false;
}

/**
 * Stop all active capture processes
 */
void MediaCaptureClient::stopCapture(StopCaptureCallback stopCallback, void* context) {
    std::lock_guard<std::mutex> lock(captureMutex);
    
    if (!isCapturing.load()) {
        if (stopCallback) {
            stopCallback(context);
        }
        return;
    }

    isCapturing.store(false);
    
    if (audioImpl) {
        audioImpl->stop(nullptr, nullptr);
        audioImpl.reset();
    }
    
    if (videoImpl) {
        videoImpl->stop(nullptr, nullptr);
        videoImpl.reset();
    }
    
    if (stopCallback) {
        stopCallback(context);
    }
}

/**
 * Handle error reporting
 */
void MediaCaptureClient::setError(const std::string& message) {
    lastErrorMessage = message;
    std::cerr << "MediaCaptureClient error: " << message << std::endl;
}

/**
 * Callback function for monitor enumeration
 */
BOOL CALLBACK MonitorEnumProc(HMONITOR hMonitor, HDC hdcMonitor, LPRECT lprcMonitor, LPARAM dwData) {
    auto targets = reinterpret_cast<std::vector<MediaCaptureTargetC>*>(dwData);
    auto titleStrings = reinterpret_cast<std::vector<std::string>*>(reinterpret_cast<void**>(dwData)[1]);
    auto appNameStrings = reinterpret_cast<std::vector<std::string>*>(reinterpret_cast<void**>(dwData)[2]);
    
    MONITORINFOEX monitorInfo;
    monitorInfo.cbSize = sizeof(MONITORINFOEX);
    if (GetMonitorInfo(hMonitor, &monitorInfo)) {
        MediaCaptureTargetC target = {};
        target.isDisplay = 1;
        target.isWindow = 0;
        
        DWORD displayID;
        POINT pt = { monitorInfo.rcMonitor.left + 1, monitorInfo.rcMonitor.top + 1 };
        HMONITOR hm = MonitorFromPoint(pt, MONITOR_DEFAULTTONULL);
        MONITORINFOEX mi;
        mi.cbSize = sizeof(mi);
        GetMonitorInfo(hm, &mi);
        
        DISPLAY_DEVICE dd = { sizeof(dd) };
        DWORD deviceIndex = 0;
        while (EnumDisplayDevices(NULL, deviceIndex, &dd, 0)) {
            if (_tcscmp(dd.DeviceName, mi.szDevice) == 0) {
                displayID = deviceIndex + 1;
                break;
            }
            deviceIndex++;
        }
        
        target.displayID = displayID;
        target.windowID = 0;
        target.width = monitorInfo.rcMonitor.right - monitorInfo.rcMonitor.left;
        target.height = monitorInfo.rcMonitor.bottom - monitorInfo.rcMonitor.top;
        
        std::string title = "Display " + std::to_string(displayID);
        if (monitorInfo.dwFlags & MONITORINFOF_PRIMARY) {
            title += " (Primary)";
        }
        titleStrings->push_back(title);
        appNameStrings->push_back("Screen");
        
        target.title = const_cast<char*>(titleStrings->back().c_str());
        target.appName = const_cast<char*>(appNameStrings->back().c_str());
        
        targets->push_back(target);
    }
    return TRUE;
}

/**
 * Callback function for window enumeration
 */
BOOL CALLBACK WindowEnumProc(HWND hwnd, LPARAM lParam) {
    auto targets = reinterpret_cast<std::vector<MediaCaptureTargetC>*>(lParam);
    auto titleStrings = reinterpret_cast<std::vector<std::string>*>(reinterpret_cast<void**>(lParam)[1]);
    auto appNameStrings = reinterpret_cast<std::vector<std::string>*>(reinterpret_cast<void**>(lParam)[2]);
    
    // Filter out invisible and disabled windows
    if (!IsWindowVisible(hwnd) || !IsWindowEnabled(hwnd)) {
        return TRUE;
    }
    
    char title[256] = { 0 };
    GetWindowTextA(hwnd, title, sizeof(title));
    
    // Skip windows with empty titles
    if (strlen(title) == 0) {
        return TRUE;
    }
    
    RECT rect;
    GetWindowRect(hwnd, &rect);
    int width = rect.right - rect.left;
    int height = rect.bottom - rect.top;
    
    // Skip very small windows
    if (width < 50 || height < 50) {
        return TRUE;
    }
    
    // Get process name for the window
    char processName[256] = { 0 };
    DWORD processId;
    GetWindowThreadProcessId(hwnd, &processId);
    
    HANDLE hProcess = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, processId);
    if (hProcess) {
        char processPath[MAX_PATH] = { 0 };
        if (GetModuleFileNameExA(hProcess, NULL, processPath, MAX_PATH)) {
            char* filename = strrchr(processPath, '\\');
            if (filename) {
                strcpy_s(processName, sizeof(processName), filename + 1);
            } else {
                strcpy_s(processName, sizeof(processName), processPath);
            }
        }
        CloseHandle(hProcess);
    }
    
    // Create and populate target info
    MediaCaptureTargetC target = {};
    target.isDisplay = 0;
    target.isWindow = 1;
    target.displayID = 0;
    target.windowID = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(hwnd));
    target.width = width;
    target.height = height;
    
    titleStrings->push_back(title);
    appNameStrings->push_back(processName[0] ? processName : "Unknown");
    
    target.title = const_cast<char*>(titleStrings->back().c_str());
    target.appName = const_cast<char*>(appNameStrings->back().c_str());
    
    targets->push_back(target);
    
    return TRUE;
}

/**
 * Enumerate available capture targets based on requested type
 */
void MediaCaptureClient::enumerateTargets(
    int targetType,
    EnumerateMediaCaptureTargetsCallback callback,
    void* context
) {
    try {
        HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
        if (FAILED(hr) && hr != S_FALSE && hr != RPC_E_CHANGED_MODE) {
            char errorMsg[256];
            snprintf(errorMsg, sizeof(errorMsg), "Failed to initialize COM: 0x%lx", hr);
            callback(nullptr, 0, errorMsg, context);
            return;
        }
        
        std::vector<MediaCaptureTargetC> targets;
        
        // Target types: 0=all, 1=screens only, 2=windows only
        bool includeScreens = (targetType == 0 || targetType == 1);
        bool includeWindows = (targetType == 0 || targetType == 2);
        bool includeAudio = (targetType == 0);
        
        // Add audio targets if requested
        if (includeAudio) {
            // System audio output
            MediaCaptureTargetC target = {};
            target.isDisplay = 0;
            target.isWindow = 1;
            target.displayID = 0;
            target.windowID = 100;
            target.width = 0;
            target.height = 0;
            target.title = nullptr;
            target.appName = nullptr;
            targets.push_back(target);
            
            // Microphone input
            MediaCaptureTargetC micTarget = {};
            micTarget.isDisplay = 0;
            micTarget.isWindow = 1;
            micTarget.displayID = 0;
            micTarget.windowID = 101;
            micTarget.width = 0;
            micTarget.height = 0;
            micTarget.title = nullptr;
            micTarget.appName = nullptr;
            targets.push_back(micTarget);
        }
        
        // Add display targets if requested
        if (includeScreens) {
            int displayCount = 0;
            EnumDisplayMonitors(NULL, NULL, 
                [](HMONITOR hMonitor, HDC hdcMonitor, LPRECT lprcMonitor, LPARAM dwData) -> BOOL {
                    (*reinterpret_cast<int*>(dwData))++;
                    return TRUE;
                }, reinterpret_cast<LPARAM>(&displayCount));
            
            for (int i = 0; i < displayCount; i++) {
                MediaCaptureTargetC displayTarget = {};
                displayTarget.isDisplay = 1;
                displayTarget.isWindow = 0;
                displayTarget.displayID = i + 1;
                displayTarget.windowID = 0;
                displayTarget.width = GetSystemMetrics(SM_CXSCREEN);
                displayTarget.height = GetSystemMetrics(SM_CYSCREEN);
                displayTarget.title = nullptr;
                displayTarget.appName = nullptr;
                targets.push_back(displayTarget);
            }
        }
        
        // Add entire desktop if windows are requested
        if (includeWindows) {
            HWND desktopHwnd = GetDesktopWindow();
            if (desktopHwnd) {
                MediaCaptureTargetC desktopTarget = {};
                desktopTarget.isDisplay = 0;
                desktopTarget.isWindow = 1;
                desktopTarget.displayID = 0;
                desktopTarget.windowID = 200;
                
                RECT rect;
                if (GetWindowRect(desktopHwnd, &rect)) {
                    desktopTarget.width = rect.right - rect.left;
                    desktopTarget.height = rect.bottom - rect.top;
                } else {
                    desktopTarget.width = GetSystemMetrics(SM_CXSCREEN);
                    desktopTarget.height = GetSystemMetrics(SM_CYSCREEN);
                }
                
                desktopTarget.title = nullptr;
                desktopTarget.appName = nullptr;
                
                targets.push_back(desktopTarget);
            }
        }
        
        // Allocate string buffer for target strings
        std::vector<char> stringBuffer;
        size_t requiredSize = 0;
        requiredSize += 20 * targets.size(); // title strings
        requiredSize += 20 * targets.size(); // app name strings
        
        stringBuffer.resize(requiredSize, 0);
        char* bufferPtr = stringBuffer.data();
        
        // Populate string information for each target
        for (size_t i = 0; i < targets.size(); i++) {
            MediaCaptureTargetC& target = targets[i];
            
            if (target.windowID == 100) {
                target.title = bufferPtr;
                strcpy(bufferPtr, "System Audio Output");
                bufferPtr += strlen("System Audio Output") + 1;
            } else if (target.windowID == 101) {
                target.title = bufferPtr;
                strcpy(bufferPtr, "Microphone Input");
                bufferPtr += strlen("Microphone Input") + 1;
            } else if (target.isDisplay) {
                target.title = bufferPtr;
                sprintf(bufferPtr, "Display %d", target.displayID);
                bufferPtr += strlen(bufferPtr) + 1;
            } else if (target.windowID == 200) {
                target.title = bufferPtr;
                strcpy(bufferPtr, "Entire Desktop");
                bufferPtr += strlen("Entire Desktop") + 1;
            } else {
                target.title = bufferPtr;
                strcpy(bufferPtr, "Unknown Window");
                bufferPtr += strlen("Unknown Window") + 1;
            }
            
            if (target.windowID == 100) {
                target.appName = bufferPtr;
                strcpy(bufferPtr, "Desktop Audio");
                bufferPtr += strlen("Desktop Audio") + 1;
            } else if (target.windowID == 101) {
                target.appName = bufferPtr;
                strcpy(bufferPtr, "Microphone");
                bufferPtr += strlen("Microphone") + 1;
            } else if (target.isDisplay) {
                target.appName = bufferPtr;
                strcpy(bufferPtr, "Screen");
                bufferPtr += strlen("Screen") + 1;
            } else {
                target.appName = bufferPtr;
                strcpy(bufferPtr, "Window");
                bufferPtr += strlen("Window") + 1;
            }
        }
        
        CoUninitialize();
        
        // Provide results through callback
        if (targets.empty()) {
            callback(nullptr, 0, nullptr, context);
        } else {
            callback(targets.data(), static_cast<int32_t>(targets.size()), nullptr, context);
        }
    }
    catch (const std::exception& e) {
        callback(nullptr, 0, const_cast<char*>(e.what()), context);
    }
    catch (...) {
        callback(nullptr, 0, const_cast<char*>("Unknown error in enumerateTargets"), context);
    }
}
