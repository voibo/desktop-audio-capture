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
    //std::string errorMessage = "error message";
    //exitCallback((char *)errorMessage.c_str(), context);

    /*
    // enable the following COM initialization code
    // for testing in non-electron nodejs environment:

    std::cerr << "COM: non electron environment, initializing windows com";
    ((AudioCaptureClient *)client)->initializeCom(); // FIXME: remove for electron

    */

    ((AudioCaptureClient *)client)->startCapture(cc, dataCallback, exitCallback, context);
}

void  stopCapture(void *client, StopCaptureCallback stopCallback, void *context) {
    ((AudioCaptureClient*)client)->stopCapture(stopCallback, context);
}