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
    frameInterval(1000) // Default 1 FPS
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
    
    if (gdiplusToken != 0) {
        Gdiplus::GdiplusShutdown(gdiplusToken);
    }
}

bool VideoCaptureImpl::start(
    const MediaCaptureConfigC &config, MediaCaptureDataCallback videoCallback, MediaCaptureExitCallback exitCallback,
    void *context) {
  this->config = config;

  float frameRate = config.frameRate;
  if (frameRate <= 0) {
    frameRate = 30.0f; // Default frame rate
  }

  frameInterval = std::chrono::milliseconds(static_cast<int>(1000.0f / frameRate));

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

bool VideoCaptureImpl::setupD3D11(UINT displayID) {
  HRESULT hr = D3D11CreateDevice(
      nullptr,                  // Default adapter
      D3D_DRIVER_TYPE_HARDWARE, // Hardware driver
      nullptr,                  // Not software driver
      0,                        // No flags
      nullptr,                  // No feature levels array
      0,                        // Size of feature levels array
      D3D11_SDK_VERSION,        // SDK version
      &device,                  // Device
      nullptr,                  // Feature level result
      &context                  // Device context
  );

  if (FAILED(hr)) {
    snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to create D3D11 device: 0x%lx", hr);
    return false;
  }

  return true;
}

bool VideoCaptureImpl::setupDuplication(UINT displayID) {
  IDXGIDevice *dxgiDevice = nullptr;
  HRESULT      hr         = device->QueryInterface(__uuidof(IDXGIDevice), reinterpret_cast<void **>(&dxgiDevice));
  if (FAILED(hr)) {
    snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to get DXGI device: 0x%lx", hr);
    return false;
  }

  IDXGIAdapter *adapter = nullptr;
  hr                    = dxgiDevice->GetAdapter(&adapter);
  dxgiDevice->Release();
  if (FAILED(hr)) {
    snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to get DXGI adapter: 0x%lx", hr);
    return false;
  }

  // Select monitor based on displayID (0-based index)
  // Use first monitor for default or invalid values
  IDXGIOutput *output      = nullptr;
  UINT         outputIndex = (displayID > 0) ? (displayID - 1) : 0;

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

  desktopWidth  = outputDesc.DesktopCoordinates.right - outputDesc.DesktopCoordinates.left;
  desktopHeight = outputDesc.DesktopCoordinates.bottom - outputDesc.DesktopCoordinates.top;

  IDXGIOutput1 *output1 = nullptr;
  hr                    = output->QueryInterface(__uuidof(IDXGIOutput1), reinterpret_cast<void **>(&output1));
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

  // Create staging texture (CPU accessible)
  D3D11_TEXTURE2D_DESC desc;
  ZeroMemory(&desc, sizeof(desc));
  desc.Width              = desktopWidth;
  desc.Height             = desktopHeight;
  desc.MipLevels          = 1;
  desc.ArraySize          = 1;
  desc.Format             = DXGI_FORMAT_B8G8R8A8_UNORM; // Standard RGBA format
  desc.SampleDesc.Count   = 1;
  desc.SampleDesc.Quality = 0;
  desc.Usage              = D3D11_USAGE_STAGING;
  desc.BindFlags          = 0;
  desc.CPUAccessFlags     = D3D11_CPU_ACCESS_READ;
  desc.MiscFlags          = 0;

  hr = device->CreateTexture2D(&desc, NULL, &stagingTexture);
  if (FAILED(hr)) {
    snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to create staging texture: 0x%lx", hr);
    return false;
  }

  return true;
}

void VideoCaptureImpl::captureThreadProc(
    MediaCaptureDataCallback videoCallback, MediaCaptureExitCallback exitCallback, void *context) {
  lastFrameTime = std::chrono::high_resolution_clock::now();

  while (isCapturing.load()) {
    auto currentTime = std::chrono::high_resolution_clock::now();
    auto elapsed     = std::chrono::duration_cast<std::chrono::milliseconds>(currentTime - lastFrameTime);

    // Wait until next frame time based on frame rate
    if (elapsed < frameInterval) {
      std::this_thread::sleep_for(frameInterval - elapsed);
      currentTime = std::chrono::high_resolution_clock::now();
    }

    lastFrameTime = currentTime;

    if (!captureFrame()) {
      continue;
    }

    uint8_t *frameData   = nullptr;
    int      width       = 0;
    int      height      = 0;
    int      bytesPerRow = 0;

    if (!processFrame(&frameData, &width, &height, &bytesPerRow)) {
      if (isCapturing.load() && exitCallback) {
        exitCallback(errorMsg, context);
      }
      continue;
    }

    // Encode frame to JPEG with quality based on config
    std::vector<uint8_t> jpegData;
    int                  quality = 90; // Default quality

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

bool VideoCaptureImpl::captureFrame() {
    if (!duplication) {
        return false;
    }
    
    IDXGIResource *desktopResource = nullptr;
    DXGI_OUTDUPL_FRAME_INFO frameInfo;
    
    // Set timeout based on frame rate (between 100ms and 500ms)
    float frameRate = 1000.0f / std::chrono::duration_cast<std::chrono::milliseconds>(frameInterval).count();
    UINT timeoutMs = (std::min)(500U, (std::max)(100U, static_cast<UINT>(1000.0f / frameRate)));

    HRESULT hr = duplication->AcquireNextFrame(timeoutMs, &frameInfo, &desktopResource);
    
  if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
    // Force frame capture if a long time has passed since last successful frame
    auto currentTime = std::chrono::high_resolution_clock::now();
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        currentTime - lastSuccessfulFrameTime).count();
    
    // Force capture after twice the frame interval
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

bool VideoCaptureImpl::encodeFrameToJPEG(
    const uint8_t* rawData, int width, int height, int bytesPerRow,
    std::vector<uint8_t>& jpegData, int quality) {
    
    // Create bitmap from raw pixel data (BGRA format)
    Gdiplus::Bitmap bitmap(width, height, bytesPerRow, PixelFormat32bppPARGB, 
                          const_cast<uint8_t*>(rawData));
    
    // Create IStream for output
    IStream* stream = NULL;
    HRESULT hr = CreateStreamOnHGlobal(NULL, TRUE, &stream);
    if (FAILED(hr)) {
        snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to create stream: 0x%lx", hr);
        return false;
    }
    
    // Get JPEG encoder CLSID
    CLSID jpegClsid;
    int result = GetEncoderClsid(L"image/jpeg", &jpegClsid);
    if (result == -1) {
        snprintf(errorMsg, sizeof(errorMsg) - 1, "JPEG encoder not found");
        stream->Release();
        return false;
    }
    
    // Set JPEG quality
    Gdiplus::EncoderParameters encoderParams;
    encoderParams.Count = 1;
    encoderParams.Parameter[0].Guid = Gdiplus::EncoderQuality;
    encoderParams.Parameter[0].Type = Gdiplus::EncoderParameterValueTypeLong;
    encoderParams.Parameter[0].NumberOfValues = 1;
    ULONG qualityValue = quality;
    encoderParams.Parameter[0].Value = &qualityValue;
    
    // Save bitmap to stream as JPEG
    Gdiplus::Status status = bitmap.Save(stream, &jpegClsid, &encoderParams);
    if (status != Gdiplus::Ok) {
        snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to save bitmap: %d", status);
        stream->Release();
        return false;
    }
    
    // Get data from stream
    HGLOBAL hg = NULL;
    hr = GetHGlobalFromStream(stream, &hg);
    if (FAILED(hr)) {
        snprintf(errorMsg, sizeof(errorMsg) - 1, "Failed to get data from stream: 0x%lx", hr);
        stream->Release();
        return false;
    }
    
    // Copy data to output vector
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

void VideoCaptureImpl::stop(StopCaptureCallback stopCallback, void *context) {
  isCapturing.store(false);

  if (captureThread && captureThread->joinable()) {
    captureThread->join();
    delete captureThread;
    captureThread = nullptr;
  }

  cleanup();

  if (stopCallback) {
    stopCallback(context);
  }
}

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
