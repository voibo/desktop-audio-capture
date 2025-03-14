/**
 * @file videocaptureimpl.cc
 * @brief Windows implementation of desktop video capture using DXGI Desktop Duplication API
 */
#include "videocaptureimpl.h"
#include <cstring>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "ole32.lib")

VideoCaptureImpl::VideoCaptureImpl() :
    device(nullptr),
    context(nullptr),
    duplication(nullptr),
    acquiredDesktopImage(nullptr),
    stagingTexture(nullptr),
    gdiplusToken(0),
    desktopWidth(0),
    desktopHeight(0),
    captureThread(nullptr),
    isCapturing(false),
    frameInterval(1000), // Default 1 FPS
    comInitialized(false)
{
    memset(errorMsg, 0, sizeof(errorMsg));
    memset(&outputDesc, 0, sizeof(outputDesc));
    
    // Initialize GDI+
    Gdiplus::GdiplusStartupInput gdiplusStartupInput;
    Gdiplus::Status status = Gdiplus::GdiplusStartup(&gdiplusToken, &gdiplusStartupInput, NULL);
    if (status != Gdiplus::Ok) {
        snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to initialize GDI+: %d", status);
    }
}

VideoCaptureImpl::~VideoCaptureImpl() {
    if (isCapturing.load()) {
        stop(nullptr, nullptr);
    }
    
    if (comInitialized) {
        uninitializeCom();
    }
    
    if (gdiplusToken != 0) {
        Gdiplus::GdiplusShutdown(gdiplusToken);
    }
}

/**
 * Initialize COM library for current thread with proper handling for Electron environment
 */
bool VideoCaptureImpl::initializeCom() {
    if (config.isElectron == 1) {
        fprintf(stderr, "DEBUG: Skipping COM initialization in Electron environment\n");
        return true;
    }

    fprintf(stderr, "DEBUG: Attempting to initialize COM with COINIT_APARTMENTTHREADED\n");
    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    
    if (SUCCEEDED(hr)) {
        fprintf(stderr, "DEBUG: COM initialized successfully\n");
        comInitialized = true;
        return true;
    } 
    else if (hr == S_FALSE) {
        fprintf(stderr, "DEBUG: COM already initialized on this thread\n");
        return true;
    }
    else if (hr == RPC_E_CHANGED_MODE) {
        fprintf(stderr, "DEBUG: COM already initialized with different threading model\n");
        
        if (config.isElectron == 1) {
            return true;
        }
        
        fprintf(stderr, "DEBUG: Attempting to initialize COM with COINIT_MULTITHREADED\n");
        hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
        if (SUCCEEDED(hr) || hr == S_FALSE) {
            fprintf(stderr, "DEBUG: COM initialized with MULTITHREADED model\n");
            comInitialized = true;
            return true;
        }
    }
    
    snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to initialize COM: 0x%lx", hr);
    fprintf(stderr, "DEBUG: %s\n", errorMsg);
    return false;
}

void VideoCaptureImpl::uninitializeCom() {
    if (comInitialized) {
        CoUninitialize();
        comInitialized = false;
    }
}

/**
 * Start video capture with the specified configuration
 */
bool VideoCaptureImpl::start(
    const MediaCaptureConfigC &config, MediaCaptureDataCallback videoCallback, MediaCaptureExitCallback exitCallback,
    void *context) {
    this->config = config;

    fprintf(stderr, "DEBUG: VideoCaptureImpl starting with isElectron=%d\n", config.isElectron);

    float frameRate = config.frameRate;
    if (frameRate <= 0) {
        frameRate = 30.0f; // Default frame rate
    }

    frameInterval = std::chrono::milliseconds(static_cast<int>(1000.0f / frameRate));

    // Handle COM initialization based on environment
    if (config.isElectron == 1) {
        fprintf(stderr, "DEBUG: Running in Electron mode, skipping COM initialization\n");
    } else {
        if (!initializeCom()) {
            fprintf(stderr, "DEBUG: COM initialization failed: %s\n", errorMsg);
            if (exitCallback) {
                exitCallback(errorMsg, context);
            }
            return false;
        }
    }

    if (!setupD3D11(config.displayID)) {
        if (exitCallback) {
            exitCallback(errorMsg, context);
        }
        return false;
    }

    if (!setupDuplication(config.displayID)) {
        if (exitCallback) {
            exitCallback(errorMsg, context);
        }
        cleanup();
        return false;
    }

    isCapturing.store(true);
    captureThread = new std::thread(&VideoCaptureImpl::captureThreadProc, this, videoCallback, exitCallback, context);

    return true;
}

/**
 * Set up Direct3D 11 device with proper error handling and fallback to WARP if needed
 */
bool VideoCaptureImpl::setupD3D11(UINT displayID) {
  fprintf(stderr, "DEBUG: Setting up D3D11 device for display %u, isElectron=%d\n", 
          displayID, config.isElectron);

  UINT creationFlags = 0;
  if (config.isElectron == 1) {
    creationFlags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  }

  try {
    HRESULT hr = D3D11CreateDevice(
        nullptr,
        D3D_DRIVER_TYPE_HARDWARE,
        nullptr,
        creationFlags,
        nullptr,
        0,
        D3D11_SDK_VERSION,
        &device,
        nullptr,
        &context
    );

    if (FAILED(hr)) {
      fprintf(stderr, "DEBUG: Hardware D3D11 device creation failed (0x%lx), trying WARP\n", hr);
      
      // Try software renderer as fallback
      hr = D3D11CreateDevice(
          nullptr,
          D3D_DRIVER_TYPE_WARP,
          nullptr,
          creationFlags,
          nullptr,
          0,
          D3D11_SDK_VERSION,
          &device,
          nullptr,
          &context
      );
      
      if (FAILED(hr)) {
        snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to create D3D11 device: 0x%lx", hr);
        fprintf(stderr, "DEBUG: %s\n", errorMsg);
        return false;
      } else {
        fprintf(stderr, "DEBUG: WARP D3D11 device created successfully\n");
      }
    } else {
      fprintf(stderr, "DEBUG: Hardware D3D11 device created successfully\n");
    }

    return true;
  }
  catch (const std::exception& e) {
    snprintf(errorMsg, sizeof(errorMsg) - 1, "Exception creating D3D11 device: %s", e.what());
    fprintf(stderr, "DEBUG: %s\n", errorMsg);
    return false;
  }
  catch (...) {
    snprintf(errorMsg, sizeof(errorMsg) - 1, "Unknown exception creating D3D11 device");
    fprintf(stderr, "DEBUG: %s\n", errorMsg);
    return false;
  }
}

/**
 * Set up desktop duplication for the specified display
 */
bool VideoCaptureImpl::setupDuplication(UINT displayID) {
  IDXGIDevice *dxgiDevice = nullptr;
  HRESULT hr = device->QueryInterface(__uuidof(IDXGIDevice), reinterpret_cast<void **>(&dxgiDevice));
  if (FAILED(hr)) {
    snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to get DXGI device: 0x%lx", hr);
    return false;
  }

  IDXGIAdapter *adapter = nullptr;
  hr = dxgiDevice->GetAdapter(&adapter);
  dxgiDevice->Release();
  if (FAILED(hr)) {
    snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to get DXGI adapter: 0x%lx", hr);
    return false;
  }

  // Select monitor based on displayID
  IDXGIOutput *output = nullptr;
  UINT outputIndex = (displayID > 0) ? (displayID - 1) : 0;

  hr = adapter->EnumOutputs(outputIndex, &output);
  adapter->Release();
  if (FAILED(hr)) {
    snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to get DXGI output %u: 0x%lx", outputIndex, hr);
    return false;
  }

  hr = output->GetDesc(&outputDesc);
  if (FAILED(hr)) {
    output->Release();
    snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to get output description: 0x%lx", hr);
    return false;
  }

  desktopWidth = outputDesc.DesktopCoordinates.right - outputDesc.DesktopCoordinates.left;
  desktopHeight = outputDesc.DesktopCoordinates.bottom - outputDesc.DesktopCoordinates.top;

  IDXGIOutput1 *output1 = nullptr;
  hr = output->QueryInterface(__uuidof(IDXGIOutput1), reinterpret_cast<void **>(&output1));
  output->Release();
  if (FAILED(hr)) {
    snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to get IDXGIOutput1: 0x%lx", hr);
    return false;
  }

  hr = output1->DuplicateOutput(device, &duplication);
  output1->Release();
  if (FAILED(hr)) {
    snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to duplicate output: 0x%lx", hr);
    return false;
  }

  // Create staging texture for CPU access
  D3D11_TEXTURE2D_DESC desc;
  ZeroMemory(&desc, sizeof(desc));
  desc.Width = desktopWidth;
  desc.Height = desktopHeight;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.SampleDesc.Quality = 0;
  desc.Usage = D3D11_USAGE_STAGING;
  desc.BindFlags = 0;
  desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  desc.MiscFlags = 0;

  hr = device->CreateTexture2D(&desc, NULL, &stagingTexture);
  if (FAILED(hr)) {
    snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to create staging texture: 0x%lx", hr);
    return false;
  }

  return true;
}

/**
 * Main capture thread procedure
 */
void VideoCaptureImpl::captureThreadProc(
    MediaCaptureDataCallback videoCallback, MediaCaptureExitCallback exitCallback, void *context) {
  lastFrameTime = std::chrono::high_resolution_clock::now();

  while (isCapturing.load()) {
    auto currentTime = std::chrono::high_resolution_clock::now();
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(currentTime - lastFrameTime);

    // Frame rate limiting
    if (elapsed < frameInterval) {
      std::this_thread::sleep_for(frameInterval - elapsed);
      currentTime = std::chrono::high_resolution_clock::now();
    }

    lastFrameTime = currentTime;

    if (!captureFrame()) {
      continue;
    }

    uint8_t *frameData = nullptr;
    int width = 0;
    int height = 0;
    int bytesPerRow = 0;

    if (!processFrame(&frameData, &width, &height, &bytesPerRow)) {
      if (isCapturing.load() && exitCallback) {
        exitCallback(errorMsg, context);
      }
      continue;
    }

    // Encode frame to JPEG with appropriate quality
    std::vector<uint8_t> jpegData;
    int quality = 90;

    switch (config.quality) {
    case 0: // High quality
      quality = 95;
      break;
    case 1: // Medium quality
      quality = 85;
      break;
    case 2: // Low quality
      quality = 75;
      break;
    }

    if (!encodeFrameToJPEG(frameData, width, height, bytesPerRow, jpegData, quality)) {
      if (isCapturing.load() && exitCallback) {
        exitCallback(errorMsg, context);
      }
      continue;
    }

    if (videoCallback && !jpegData.empty()) {
      videoCallback(
          jpegData.data(), width, height, bytesPerRow,
          static_cast<int32_t>(
              std::chrono::duration_cast<std::chrono::milliseconds>(currentTime.time_since_epoch()).count()),
          "jpeg", jpegData.size(), context);
    }
  }
}

/**
 * Capture a single frame using Desktop Duplication API
 */
bool VideoCaptureImpl::captureFrame() {
    if (!duplication) {
        return false;
    }
    
    IDXGIResource *desktopResource = nullptr;
    DXGI_OUTDUPL_FRAME_INFO frameInfo;
    
    float frameRate = 1000.0f / std::chrono::duration_cast<std::chrono::milliseconds>(frameInterval).count();
    UINT timeoutMs = (std::min)(500U, (std::max)(100U, static_cast<UINT>(1000.0f / frameRate)));

    HRESULT hr = duplication->AcquireNextFrame(timeoutMs, &frameInfo, &desktopResource);
    
  if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
    // Handle timeout by forcing update after extended period
    auto currentTime = std::chrono::high_resolution_clock::now();
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        currentTime - lastSuccessfulFrameTime).count();
    
    if (elapsed > (2000.0f / frameRate)) {
        return true;
    }
    return false;
  } else if (FAILED(hr)) {
    snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to acquire next frame: 0x%lx", hr);
    return false;
  }

  hr = desktopResource->QueryInterface(__uuidof(ID3D11Texture2D), reinterpret_cast<void **>(&acquiredDesktopImage));
  desktopResource->Release();

  if (FAILED(hr)) {
    duplication->ReleaseFrame();
    snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to query interface for ID3D11Texture2D: 0x%lx", hr);
    return false;
  }

  context->CopyResource(stagingTexture, acquiredDesktopImage);

  acquiredDesktopImage->Release();
  acquiredDesktopImage = nullptr;
  duplication->ReleaseFrame();

  lastSuccessfulFrameTime = std::chrono::high_resolution_clock::now();

  return true;
}

/**
 * Process captured frame and make it accessible to CPU
 */
bool VideoCaptureImpl::processFrame(uint8_t **buffer, int *width, int *height, int *bytesPerRow) {
  D3D11_MAPPED_SUBRESOURCE mappedResource;
  HRESULT hr = context->Map(stagingTexture, 0, D3D11_MAP_READ, 0, &mappedResource);
  if (FAILED(hr)) {
    snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to map staging texture: 0x%lx", hr);
    return false;
  }

  UINT pitch = mappedResource.RowPitch;
  UINT bufferSize = pitch * desktopHeight;

  if (frameBuffer.size() != bufferSize) {
    frameBuffer.resize(bufferSize);
  }

  uint8_t *mappedData = static_cast<uint8_t *>(mappedResource.pData);
  for (UINT row = 0; row < desktopHeight; row++) {
    memcpy(frameBuffer.data() + row * pitch, mappedData + row * pitch, pitch);
  }

  context->Unmap(stagingTexture, 0);

  *buffer = frameBuffer.data();
  *width = desktopWidth;
  *height = desktopHeight;
  *bytesPerRow = pitch;

  return true;
}

/**
 * Encode raw frame data to JPEG format using GDI+
 */
bool VideoCaptureImpl::encodeFrameToJPEG(
    const uint8_t* rawData, int width, int height, int bytesPerRow,
    std::vector<uint8_t>& jpegData, int quality) {
    
    Gdiplus::Bitmap bitmap(width, height, bytesPerRow, PixelFormat32bppPARGB, 
                          const_cast<uint8_t*>(rawData));
    
    IStream* stream = NULL;
    HRESULT hr = CreateStreamOnHGlobal(NULL, TRUE, &stream);
    if (FAILED(hr)) {
        snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to create stream: 0x%lx", hr);
        return false;
    }
    
    CLSID jpegClsid;
    int result = GetEncoderClsid(L"image/jpeg", &jpegClsid);
    if (result == -1) {
        snprintf(errorMsg, sizeof(errorMsg) - 1, "JPEG encoder not found");
        stream->Release();
        return false;
    }
    
    Gdiplus::EncoderParameters encoderParams;
    encoderParams.Count = 1;
    encoderParams.Parameter[0].Guid = Gdiplus::EncoderQuality;
    encoderParams.Parameter[0].Type = Gdiplus::EncoderParameterValueTypeLong;
    encoderParams.Parameter[0].NumberOfValues = 1;
    ULONG qualityValue = quality;
    encoderParams.Parameter[0].Value = &qualityValue;
    
    Gdiplus::Status status = bitmap.Save(stream, &jpegClsid, &encoderParams);
    if (status != Gdiplus::Ok) {
        snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to save bitmap: %d", status);
        stream->Release();
        return false;
    }
    
    HGLOBAL hg = NULL;
    hr = GetHGlobalFromStream(stream, &hg);
    if (FAILED(hr)) {
        snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to get data from stream: 0x%lx", hr);
        stream->Release();
        return false;
    }
    
    SIZE_T size = GlobalSize(hg);
    void* data = GlobalLock(hg);
    if (data && size > 0) {
        jpegData.resize(size);
        memcpy(jpegData.data(), data, size);
        GlobalUnlock(hg);
    }
    
    stream->Release();
    
    return !jpegData.empty();
}

/**
 * Helper to find GDI+ encoder for specified format
 */
int VideoCaptureImpl::GetEncoderClsid(const WCHAR* format, CLSID* pClsid) {
    UINT num = 0;
    UINT size = 0;
    
    Gdiplus::GetImageEncodersSize(&num, &size);
    if (size == 0) return -1;
    
    Gdiplus::ImageCodecInfo* pImageCodecInfo = (Gdiplus::ImageCodecInfo*)(malloc(size));
    if (pImageCodecInfo == NULL) return -1;
    
    Gdiplus::GetImageEncoders(num, size, pImageCodecInfo);
    
    for (UINT j = 0; j < num; ++j) {
        if (wcscmp(pImageCodecInfo[j].MimeType, format) == 0) {
            *pClsid = pImageCodecInfo[j].Clsid;
            free(pImageCodecInfo);
            return j;
        }
    }
    free(pImageCodecInfo);
    return -1;
}

/**
 * Stop capture and clean up resources
 */
void VideoCaptureImpl::stop(StopCaptureCallback stopCallback, void *context) {
    isCapturing.store(false);

    if (captureThread && captureThread->joinable()) {
        captureThread->join();
        delete captureThread;
        captureThread = nullptr;
    }

    cleanup();
    
    if (comInitialized && config.isElectron != 1) {
        uninitializeCom();
    }

    if (stopCallback) {
        stopCallback(context);
    }
}

/**
 * Release all DirectX resources
 */
void VideoCaptureImpl::cleanup() {
    if (duplication) {
        duplication->Release();
        duplication = nullptr;
    }

    if (acquiredDesktopImage) {
        acquiredDesktopImage->Release();
        acquiredDesktopImage = nullptr;
    }

    if (stagingTexture) {
        stagingTexture->Release();
        stagingTexture = nullptr;
    }

    if (context) {
        context->Release();
        context = nullptr;
    }

    if (device) {
        device->Release();
        device = nullptr;
    }

    frameBuffer.clear();
}
