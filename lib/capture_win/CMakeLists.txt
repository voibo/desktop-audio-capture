add_library(capture_win STATIC AudioCapture.cc captureclient.cc)
target_link_libraries(capture_win PRIVATE samplerate)
