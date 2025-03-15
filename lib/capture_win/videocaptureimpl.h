/**
 * @file videocaptureimpl.h
 * @brief Windows video capture implementation using DXGI Desktop Duplication API
 * 
 * This class implements desktop video capture functionality for Windows systems using
 * the DXGI Desktop Duplication API and Direct3D 11. It supports capturing display content
 * with configurable parameters like quality and frame rate.
 */
#pragma once

#include <Windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <objidl.h> // For IStream
#include <gdiplus.h> // For GDI+
#include <chrono>
#include <vector>
#include <thread>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include "capture/capture.h"

/**
 * @class VideoCaptureImpl
 * @brief Windows-specific implementation of desktop video capture
 * 
 * Handles the low-level video capture functionality for Windows using DXGI Desktop Duplication API.
 * Supports display capture with configurable frame rate and compression quality.
 */
class VideoCaptureImpl {
public:
    /**
     * @brief Constructor - initializes resources to default values
     */
    VideoCaptureImpl();
    
    /**
     * @brief Destructor - ensures capture is stopped and resources are released
     */
    ~VideoCaptureImpl();

    /**
     * @brief Start video capture with specified configuration
     * 
     * @param config Media capture configuration including frame rate and quality settings
     * @param videoCallback Function called when video frame is available
     * @param exitCallback Function called when an error occurs
     * @param context User data passed to callbacks
     * @return true if capture started successfully, false otherwise
     */
    bool start(
        const MediaCaptureConfigC& config,
        MediaCaptureDataCallback videoCallback,
        MediaCaptureExitCallback exitCallback,
        void* context
    );

    /**
     * @brief Stop video capture and release resources
     * 
     * @param stopCallback Function called when capture has stopped
     * @param context User data passed to callback
     */
    void stop(
        StopCaptureCallback stopCallback,
        void* context
    );

private:
    /**
     * @name Direct3D and DXGI Resources
     * Graphics resources used for desktop frame capture
     */
    ///@{
    /** Direct3D 11 device */
    ID3D11Device* device;
    
    /** Direct3D 11 device context for rendering commands */
    ID3D11DeviceContext* context;
    
    /** Desktop duplication interface for screen capture */
    IDXGIOutputDuplication* duplication;
    
    /** Texture holding the most recently acquired desktop image */
    ID3D11Texture2D* acquiredDesktopImage;
    
    /** Staging texture for CPU access to frame data */
    ID3D11Texture2D* stagingTexture;
    ///@}
    
    /** GDI+ initialization token */
    ULONG_PTR gdiplusToken;

    /**
     * @name Frame Properties
     * Information about the captured desktop/window
     */
    ///@{
    /** Width of the desktop in pixels */
    UINT desktopWidth;
    
    /** Height of the desktop in pixels */
    UINT desktopHeight;
    
    /** DXGI output description containing display information */
    DXGI_OUTPUT_DESC outputDesc;
    ///@}
    
    /** Buffer for storing processed frame data */
    std::vector<uint8_t> frameBuffer;
    
    /**
     * @name Timing Management
     * Resources for controlling frame rate and timing
     */
    ///@{
    /** Timestamp of the last frame capture attempt */
    std::chrono::high_resolution_clock::time_point lastFrameTime;
    
    /** Timestamp of the last successful frame capture */
    std::chrono::high_resolution_clock::time_point lastSuccessfulFrameTime;
    
    /** Target interval between frames (based on frameRate setting) */
    std::chrono::milliseconds frameInterval;
    ///@}
    
    /**
     * @name Thread Management
     * Resources for controlling the background capture thread
     */
    ///@{
    /** Background thread for capture operations */
    std::thread* captureThread;
    
    /** Flag controlling capture thread execution */
    std::atomic<bool> isCapturing;
    
    /** Mutex for thread synchronization */
    std::mutex captureMutex;
    
    /** Condition variable for signaling between threads */
    std::condition_variable captureCV;
    ///@}
    
    /** Current capture configuration */
    MediaCaptureConfigC config;
    
    /** Buffer for error messages */
    char errorMsg[1024];
    
    /** Flag indicating if COM has been initialized */
    bool comInitialized;
    
    /**
     * @name Initialization Functions
     * Functions for setting up capture infrastructure
     */
    ///@{
    /**
     * @brief Initialize COM library for the current thread
     * @return true if successful, false otherwise
     */
    bool initializeCom();
    
    /**
     * @brief Clean up COM library initialization
     */
    void uninitializeCom();
    
    /**
     * @brief Set up Direct3D 11 device and context
     * @param displayID ID of the display to capture
     * @return true if successful, false otherwise
     */
    bool setupD3D11(UINT displayID);
    
    /**
     * @brief Set up desktop duplication for the specified display
     * @param displayID ID of the display to capture
     * @return true if successful, false otherwise
     */
    bool setupDuplication(UINT displayID);
    ///@}
    
    /**
     * @name Frame Processing Functions
     * Functions for capturing and processing desktop frames
     */
    ///@{
    /**
     * @brief Capture the next desktop frame
     * @return true if frame was successfully captured, false otherwise
     */
    bool captureFrame();
    
    /**
     * @brief Process the captured frame for callback delivery
     * @param buffer Pointer that will receive the frame data
     * @param width Will be set to frame width
     * @param height Will be set to frame height
     * @param bytesPerRow Will be set to row stride in bytes
     * @return true if successful, false otherwise
     */
    bool processFrame(uint8_t** buffer, int* width, int* height, int* bytesPerRow);
    
    /**
     * @brief Encode raw pixel data to JPEG format
     * @param rawData Source pixel data in BGRA format
     * @param width Image width
     * @param height Image height
     * @param bytesPerRow Row stride in bytes
     * @param jpegData Vector to receive encoded JPEG data
     * @param quality JPEG encoding quality (0-100)
     * @return true if successful, false otherwise
     */
    bool encodeFrameToJPEG(const uint8_t* rawData, int width, int height, int bytesPerRow, 
                         std::vector<uint8_t>& jpegData, int quality);
    
    /**
     * @brief Background thread procedure for video capture
     * @param videoCallback Function to call with captured video data
     * @param exitCallback Function to call if an error occurs
     * @param context User data passed to callbacks
     */
    void captureThreadProc(
        MediaCaptureDataCallback videoCallback,
        MediaCaptureExitCallback exitCallback,
        void* context
    );
    
    /**
     * @brief Clean up all resources
     */
    void cleanup();
    ///@}

    /**
     * @brief Helper method to get CLSID for a GDI+ encoder
     * @param format Format name (e.g., L"image/jpeg")
     * @param pClsid Pointer to receive the CLSID
     * @return Index of the encoder if found, -1 if not found
     */
    int GetEncoderClsid(const WCHAR* format, CLSID* pClsid);
};