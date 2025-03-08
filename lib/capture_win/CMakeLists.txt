add_library(capture_win STATIC AudioCapture.cc captureclient.cc MediaCaptureWin.cc MediaCaptureWin.h)
target_link_libraries(capture_win PRIVATE samplerate)

# Windows specific dependencies
if(WIN32)
  target_link_libraries(capture_win PRIVATE ole32 oleaut32 winmm)
endif()

# Include directories
target_include_directories(capture_win PRIVATE ${CMAKE_SOURCE_DIR})
