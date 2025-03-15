/**
 * @file mediacaptureclient.h
 * @brief Media capture client implementation for Windows
 * 
 * This header defines the Media Capture Client class which provides a high-level
 * interface for capturing audio and video from various sources on Windows systems.
 * It coordinates audio and video capture implementations and handles resource management.
 */
#pragma once

#include <memory>
#include <atomic>
#include <mutex>
#include <string>
#include "capture/capture.h"

// Forward declarations
class AudioCaptureImpl;
class VideoCaptureImpl;

/**
 * @class MediaCaptureClient
 * @brief High-level client for desktop audio and video capture onX Windows
 * 
 * Manages audio and video capture subsystems, provides a unified interface for
 * capturing from system audio, microphones, displays and windows. Handles COM initialization,
 * device enumeration, capture synchronization and error handling.
 */
class MediaCaptureClient {
public:
    /**
     * @brief Constructor - initializes the capture client
     * 
     * Creates an instance of the media capture client with audio and video
     * capture implementations ready to be initialized.
     */
    MediaCaptureClient();
    
    /**
     * @brief Destructor - ensures capture is stopped and resources released
     */
    ~MediaCaptureClient();

    /**
     * @brief Initialize COM library for the current thread
     * 
     * Sets up the Component Object Model (COM) library with appropriate
     * threading model for media capture operations.
     */
    void initializeCom();
    
    /**
     * @brief Clean up COM library initialization
     * 
     * Releases COM library resources when they are no longer needed.
     */
    void uninitializeCom();

    /**
     * @brief Start audio-only capture
     * 
     * Initializes and starts audio capture with the specified configuration.
     * 
     * @param config Capture configuration including audio parameters
     * @param audioCallback Function to receive audio data
     * @param exitCallback Function called when capture exits or errors occur
     * @param context User data pointer passed to callbacks
     * @return true if capture started successfully, false otherwise
     */
    bool startCapture(
        const MediaCaptureConfigC& config,
        MediaCaptureAudioDataCallback audioCallback,
        MediaCaptureExitCallback exitCallback,
        void* context
    );
    
    /**
     * @brief Start combined audio and video capture
     * 
     * Initializes and starts both audio and video capture with the specified configuration.
     * Either audio or video capture can be omitted by passing NULL for the respective callback.
     * 
     * @param config Capture configuration including audio and video parameters
     * @param videoCallback Function to receive video frames
     * @param audioCallback Function to receive audio data
     * @param exitCallback Function called when capture exits or errors occur
     * @param context User data pointer passed to callbacks
     * @return true if at least one capture type started successfully, false otherwise
     */
    bool startCapture(
        const MediaCaptureConfigC& config,
        MediaCaptureDataCallback videoCallback,
        MediaCaptureAudioDataCallback audioCallback,
        MediaCaptureExitCallback exitCallback,
        void* context
    );

    /**
     * @brief Stop all active capture operations
     * 
     * Stops any active audio or video capture and releases resources.
     * 
     * @param stopCallback Function called when capture has been stopped
     * @param context User data pointer passed to callback
     */
    void stopCapture(
        StopCaptureCallback stopCallback,
        void* context
    );

    /**
     * @brief Enumerate available capture targets
     * 
     * Provides information about available capture sources including
     * displays, windows, system audio output, and microphone input.
     * 
     * @param targetType Type of targets to enumerate:
     *                  0=all, 1=displays only, 2=windows only
     * @param callback Function to receive enumeration results
     * @param context User data pointer passed to callback
     */
    static void enumerateTargets(
        int targetType,
        EnumerateMediaCaptureTargetsCallback callback,
        void* context
    );

private:
    /**
     * @name Implementation Components
     * @{
     */
    /** Audio capture implementation */
    std::unique_ptr<AudioCaptureImpl> audioImpl;
    
    /** Video capture implementation */
    std::unique_ptr<VideoCaptureImpl> videoImpl;
    /**@}*/
    
    /**
     * @name State Management
     * @{
     */
    /** Flag indicating if capture is currently active */
    std::atomic<bool> isCapturing;
    
    /** Mutex for thread-safe operations on capture state */
    std::mutex captureMutex;
    /**@}*/
    
    /**
     * @name Error Handling
     * @{
     */
    /** Last error message */
    std::string lastErrorMessage;
    
    /**
     * @brief Set error message and log it
     * @param message The error message to set
     */
    void setError(const std::string& message);
    /**@}*/
};