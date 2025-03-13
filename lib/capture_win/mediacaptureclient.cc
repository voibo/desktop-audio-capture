// ライブラリのリンク指定
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "psapi.lib")

// 先にすべての必要なヘッダーをインクルード
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

MediaCaptureClient::MediaCaptureClient() : isCapturing(false) {
    audioImpl = std::make_unique<AudioCaptureImpl>();
}

MediaCaptureClient::~MediaCaptureClient() {
    // Ensure capture is stopped before destruction
    if (isCapturing.load()) {
        stopCapture(nullptr, nullptr);
    }
}

void MediaCaptureClient::initializeCom() {
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr) && hr != S_FALSE && hr != RPC_E_CHANGED_MODE) {
        std::stringstream ss;
        ss << "Failed to initialize COM: 0x" << std::hex << hr;
        setError(ss.str());
    }
}

void MediaCaptureClient::uninitializeCom() {
    CoUninitialize();
}

bool MediaCaptureClient::startCapture(
    const MediaCaptureConfigC& config,
    MediaCaptureDataCallback videoCallback,
    MediaCaptureAudioDataCallback audioCallback,
    MediaCaptureExitCallback exitCallback,
    void* context
) {
    std::lock_guard<std::mutex> lock(captureMutex);
    
    if (isCapturing.load()) {
        if (exitCallback) {
            exitCallback("Capture already in progress", context);
        }
        return false;
    }

    bool audioResult = true;
    bool videoResult = true;

    // オーディオキャプチャを開始（要求されている場合）
    if (audioCallback) {
        audioImpl = std::make_unique<AudioCaptureImpl>();
        audioResult = audioImpl->start(config, audioCallback, exitCallback, context);
    }

    // ビデオキャプチャを開始（要求されている場合）
    if (videoCallback && (config.displayID > 0 || config.windowID > 0)) {
        videoImpl = std::make_unique<VideoCaptureImpl>();
        videoResult = videoImpl->start(config, videoCallback, exitCallback, context);
    }

    // どちらかが成功していれば、キャプチャを開始したとみなす
    if (audioResult || videoResult) {
        isCapturing.store(true);
        return true;
    }
    
    return false;
}

void MediaCaptureClient::stopCapture(StopCaptureCallback stopCallback, void* context) {
    std::lock_guard<std::mutex> lock(captureMutex);
    
    if (!isCapturing.load()) {
        if (stopCallback) {
            stopCallback(context);
        }
        return;
    }

    isCapturing.store(false);
    
    // 単純化：両方のキャプチャを同期的に停止する
    if (audioImpl) {
        audioImpl->stop(nullptr, nullptr);
        audioImpl.reset();
    }
    
    if (videoImpl) {
        videoImpl->stop(nullptr, nullptr);
        videoImpl.reset();
    }
    
    // 両方のキャプチャが停止したら、コールバックを呼び出す
    if (stopCallback) {
        stopCallback(context);
    }
}

void MediaCaptureClient::setError(const std::string& message) {
    lastErrorMessage = message;
    std::cerr << "MediaCaptureClient error: " << message << std::endl;
}

// EnumDisplayMonitors用コールバック関数
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
        
        // DisplayIDをモニタハンドルから取得する代替手段
        DWORD displayID;
        POINT pt = { monitorInfo.rcMonitor.left + 1, monitorInfo.rcMonitor.top + 1 };
        HMONITOR hm = MonitorFromPoint(pt, MONITOR_DEFAULTTONULL);
        MONITORINFOEX mi;
        mi.cbSize = sizeof(mi);
        GetMonitorInfo(hm, &mi);
        
        // デバイス名からIDを抽出
        DISPLAY_DEVICE dd = { sizeof(dd) };
        DWORD deviceIndex = 0;
        while (EnumDisplayDevices(NULL, deviceIndex, &dd, 0)) {
            if (_tcscmp(dd.DeviceName, mi.szDevice) == 0) {
                // DeviceIDを数値に変換（単純化のため）
                displayID = deviceIndex + 1;
                break;
            }
            deviceIndex++;
        }
        
        target.displayID = displayID;
        target.windowID = 0;
        target.width = monitorInfo.rcMonitor.right - monitorInfo.rcMonitor.left;
        target.height = monitorInfo.rcMonitor.bottom - monitorInfo.rcMonitor.top;
        
        // モニタ名を取得
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

// EnumWindows用コールバック関数
BOOL CALLBACK WindowEnumProc(HWND hwnd, LPARAM lParam) {
    auto targets = reinterpret_cast<std::vector<MediaCaptureTargetC>*>(lParam);
    auto titleStrings = reinterpret_cast<std::vector<std::string>*>(reinterpret_cast<void**>(lParam)[1]);
    auto appNameStrings = reinterpret_cast<std::vector<std::string>*>(reinterpret_cast<void**>(lParam)[2]);
    
    // ウィンドウが可視かつ有効な状態かチェック
    if (!IsWindowVisible(hwnd) || !IsWindowEnabled(hwnd)) {
        return TRUE; // 次のウィンドウへ
    }
    
    // タイトルを取得
    char title[256] = { 0 };
    GetWindowTextA(hwnd, title, sizeof(title));
    
    // タイトルが空のウィンドウはスキップ
    if (strlen(title) == 0) {
        return TRUE;
    }
    
    // ウィンドウサイズを取得
    RECT rect;
    GetWindowRect(hwnd, &rect);
    int width = rect.right - rect.left;
    int height = rect.bottom - rect.top;
    
    // サイズが小さすぎるウィンドウはスキップ
    if (width < 50 || height < 50) {
        return TRUE;
    }
    
    // プロセス名を取得
    char processName[256] = { 0 };
    DWORD processId;
    GetWindowThreadProcessId(hwnd, &processId);
    
    HANDLE hProcess = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, processId);
    if (hProcess) {
        char processPath[MAX_PATH] = { 0 };
        if (GetModuleFileNameExA(hProcess, NULL, processPath, MAX_PATH)) {
            // パスから実行ファイル名のみを抽出
            char* filename = strrchr(processPath, '\\');
            if (filename) {
                strcpy_s(processName, sizeof(processName), filename + 1);
            } else {
                strcpy_s(processName, sizeof(processName), processPath);
            }
        }
        CloseHandle(hProcess);
    }
    
    // ターゲットを作成
    MediaCaptureTargetC target = {};
    target.isDisplay = 0;
    target.isWindow = 1;
    target.displayID = 0;
    target.windowID = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(hwnd)); // 適切な型変換    target.width = width;
    target.height = height;
    
    titleStrings->push_back(title);
    appNameStrings->push_back(processName[0] ? processName : "Unknown");
    
    target.title = const_cast<char*>(titleStrings->back().c_str());
    target.appName = const_cast<char*>(appNameStrings->back().c_str());
    
    targets->push_back(target);
    
    return TRUE;
}

void MediaCaptureClient::enumerateTargets(
    int targetType,
    EnumerateMediaCaptureTargetsCallback callback,
    void* context
) {
    // より安全なアプローチで実装
    try {
        // Initialize COM
        HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
        if (FAILED(hr) && hr != S_FALSE && hr != RPC_E_CHANGED_MODE) {
            char errorMsg[256];
            snprintf(errorMsg, sizeof(errorMsg), "Failed to initialize COM: 0x%lx", hr);
            callback(nullptr, 0, errorMsg, context);
            return;
        }
        
        std::vector<MediaCaptureTargetC> targets;
        
        // Mac版と同様のtargetTypeの解釈
        // 0: すべて, 1: 画面のみ, 2: ウィンドウのみ
        bool includeScreens = (targetType == 0 || targetType == 1);
        bool includeWindows = (targetType == 0 || targetType == 2);
        bool includeAudio = (targetType == 0); // 音声は"all"の場合のみ
        
        // --- 音声デバイスの追加 (最も安全なため、これから開始) ---
        if (includeAudio) {
            // System Audio Output
            MediaCaptureTargetC target = {};
            target.isDisplay = 0;
            target.isWindow = 1;
            target.displayID = 0;
            target.windowID = 100;  // Special ID for system audio output
            target.width = 0;
            target.height = 0;
            
            // 文字列は後で一度に割り当て
            target.title = nullptr;
            target.appName = nullptr;
            
            targets.push_back(target);
            
            // Microphone Input
            MediaCaptureTargetC micTarget = {};
            micTarget.isDisplay = 0;
            micTarget.isWindow = 1;
            micTarget.displayID = 0;
            micTarget.windowID = 101;  // Special ID for microphone input
            micTarget.width = 0;
            micTarget.height = 0;
            
            // 文字列は後で一度に割り当て
            micTarget.title = nullptr;
            micTarget.appName = nullptr;
            
            targets.push_back(micTarget);
        }
        
        // --- スクリーンを追加 ---
        if (includeScreens) {
            // 簡易版：複雑なコールバックを避け、短いスコープでモニター情報を取得
            int displayCount = 0;
            EnumDisplayMonitors(NULL, NULL, 
                [](HMONITOR hMonitor, HDC hdcMonitor, LPRECT lprcMonitor, LPARAM dwData) -> BOOL {
                    (*reinterpret_cast<int*>(dwData))++;
                    return TRUE;
                }, reinterpret_cast<LPARAM>(&displayCount));
            
            // 各モニターの基本情報を取得
            for (int i = 0; i < displayCount; i++) {
                MediaCaptureTargetC displayTarget = {};
                displayTarget.isDisplay = 1;
                displayTarget.isWindow = 0;
                displayTarget.displayID = i + 1;  // 1-ベースのインデックス
                displayTarget.windowID = 0;
                
                // ディスプレイの解像度はあとで設定
                displayTarget.width = GetSystemMetrics(SM_CXSCREEN);  // 簡易実装
                displayTarget.height = GetSystemMetrics(SM_CYSCREEN); // 簡易実装
                
                // 文字列は後で一度に割り当て
                displayTarget.title = nullptr;
                displayTarget.appName = nullptr;
                
                targets.push_back(displayTarget);
            }
        }
        
        // --- ウィンドウを追加 ---
        if (includeWindows) {
            // ここでは、簡易版として重要なウィンドウだけを追加
            // 本来はEnumWindowsを使用するが、安定性のためにシンプルにする
            HWND desktopHwnd = GetDesktopWindow();
            if (desktopHwnd) {
                MediaCaptureTargetC desktopTarget = {};
                desktopTarget.isDisplay = 0;
                desktopTarget.isWindow = 1;
                desktopTarget.displayID = 0;
                desktopTarget.windowID = 200;  // 特別なID
                
                RECT rect;
                if (GetWindowRect(desktopHwnd, &rect)) {
                    desktopTarget.width = rect.right - rect.left;
                    desktopTarget.height = rect.bottom - rect.top;
                } else {
                    desktopTarget.width = GetSystemMetrics(SM_CXSCREEN);
                    desktopTarget.height = GetSystemMetrics(SM_CYSCREEN);
                }
                
                // 文字列は後で一度に割り当て
                desktopTarget.title = nullptr;
                desktopTarget.appName = nullptr;
                
                targets.push_back(desktopTarget);
            }
        }
        
        // 文字列の割り当て（単一のメモリブロックを使用）
        std::vector<char> stringBuffer;
        size_t requiredSize = 0;
        
        // 必要なバッファサイズを計算
        requiredSize += 20 * targets.size(); // タイトル用に20バイト/ターゲット
        requiredSize += 20 * targets.size(); // アプリ名用に20バイト/ターゲット
        
        // バッファのサイズ調整
        stringBuffer.resize(requiredSize, 0);
        char* bufferPtr = stringBuffer.data();
        
        // 各ターゲットに文字列を割り当て
        for (size_t i = 0; i < targets.size(); i++) {
            MediaCaptureTargetC& target = targets[i];
            
            // タイトルを設定
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
            
            // アプリ名を設定
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
        
        // COMの終了
        CoUninitialize();
        
        // 結果をコールバックで返す
        if (targets.empty()) {
            callback(nullptr, 0, nullptr, context);
        } else {
            callback(targets.data(), static_cast<int32_t>(targets.size()), nullptr, context);
        }
        
        // メモリは自動的に解放される（std::vectorのスコープ終了時）
    }
    catch (const std::exception& e) {
        // 例外が発生した場合、エラーメッセージを返す
        callback(nullptr, 0, const_cast<char*>(e.what()), context);
    }
    catch (...) {
        // 不明な例外
        callback(nullptr, 0, const_cast<char*>("Unknown error in enumerateTargets"), context);
    }
}
