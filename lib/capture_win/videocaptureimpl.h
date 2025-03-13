#pragma once

#include <Windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <objidl.h> // IStream用
#include <gdiplus.h> // GDI+用
#include <chrono>
#include <vector>
#include <thread>
#include <atomic>
#include <mutex>
#include "capture/capture.h"

class VideoCaptureImpl {
public:
    VideoCaptureImpl();
    ~VideoCaptureImpl();

    bool start(
        const MediaCaptureConfigC& config,
        MediaCaptureDataCallback videoCallback,
        MediaCaptureExitCallback exitCallback,
        void* context
    );

    void stop(
        StopCaptureCallback stopCallback,
        void* context
    );

private:
    // D3D11 and DXGI resources
    ID3D11Device* device;
    ID3D11DeviceContext* context;
    IDXGIOutputDuplication* duplication;
    ID3D11Texture2D* acquiredDesktopImage;
    ID3D11Texture2D* stagingTexture;
    
    // GDI+用のトークン
    ULONG_PTR gdiplusToken;

    // Frame processing
    UINT desktopWidth;
    UINT desktopHeight;
    DXGI_OUTPUT_DESC outputDesc;
    
    // Frame buffer
    std::vector<uint8_t> frameBuffer;
    
    // Timing management
    std::chrono::high_resolution_clock::time_point lastFrameTime;
    std::chrono::high_resolution_clock::time_point lastSuccessfulFrameTime;
    std::chrono::milliseconds frameInterval;
    
    // Thread management
    std::thread* captureThread;
    std::atomic<bool> isCapturing;
    std::mutex captureMutex;
    std::condition_variable captureCV;
    
    // Configuration
    MediaCaptureConfigC config;
    char errorMsg[1024];
    
    // メソッド宣言は変更なし
    bool setupD3D11(UINT displayID);
    bool setupDuplication(UINT displayID);
    bool captureFrame();
    bool processFrame(uint8_t** buffer, int* width, int* height, int* bytesPerRow);
    bool encodeFrameToJPEG(const uint8_t* rawData, int width, int height, int bytesPerRow, 
                         std::vector<uint8_t>& jpegData, int quality);
    void captureThreadProc(
        MediaCaptureDataCallback videoCallback,
        MediaCaptureExitCallback exitCallback,
        void* context
    );
    void cleanup();

    // GDI+用のヘルパーメソッド
    int GetEncoderClsid(const WCHAR* format, CLSID* pClsid);
};