add_library(capture_win STATIC 
    AudioCapture.cc 
    captureclient.cc 
    MediaCaptureWin.cc 
    mediacaptureclient.cc
    audiocaptureimpl.cc
    videocaptureimpl.cc
)
target_link_libraries(capture_win PRIVATE samplerate)

# Windows specific dependencies - GDI+用ライブラリを追加
if(WIN32)
  target_link_libraries(capture_win PRIVATE ole32 oleaut32 winmm d3d11 dxgi gdiplus)
endif()

# Include directories
target_include_directories(capture_win PRIVATE ${CMAKE_SOURCE_DIR})
