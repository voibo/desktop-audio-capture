#include "capture/capture.h"
#include "captureclient.h"
#include <string>
#include <vector>
#include <cstdlib>

void  enumerateDesktopWindows(EnumerateDesktopWindowsCallback cb, void *ctx) {
    std::vector<std::string> windowTitleStrings;
    std::vector<char *> windowTitlePointers;
    windowTitleStrings.push_back("Windows Desktop (all applications)");
    windowTitlePointers.push_back((char *)windowTitleStrings[0].c_str());
    char *error = NULL;

    int displayCount = 1;
    DisplayInfo displays[] = {
        {
            1
        },
    };

    int windowCount = 1;
    WindowInfo windows[] = {
        {
          1,
          windowTitlePointers[0]
        }
    };

    cb(displays, displayCount, windows, windowCount, error, ctx);
}

void *createCapture(void) {
  return new AudioCaptureClient();
}

void  destroyCapture(void *client) {
    delete (AudioCaptureClient*) client;
}

void  startCapture(void *client, CaptureConfig cc, StartCaptureDataCallback dataCallback, StartCaptureExitCallback exitCallback, void *context) {
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    
    if (hr == S_OK) {
        std::cerr << "COM initialized successfully" << std::endl;
    } else if (hr == S_FALSE) {
        std::cerr << "COM was already initialized (expected in Electron)" << std::endl;
    } else if (hr == RPC_E_CHANGED_MODE) {
        std::cerr << "COM already initialized with different thread model" << std::endl;
    } else {
        std::cerr << "Failed to initialize COM: 0x" << std::hex << hr << std::endl;
        std::string error = "Failed to initialize COM: ";
        error += std::to_string(hr);
        exitCallback((char*)error.c_str(), context);
        return;
    }

    ((AudioCaptureClient *)client)->startCapture(cc, dataCallback, exitCallback, context);
}

void  stopCapture(void *client, StopCaptureCallback stopCallback, void *context) {
    ((AudioCaptureClient*)client)->stopCapture(stopCallback, context);
}