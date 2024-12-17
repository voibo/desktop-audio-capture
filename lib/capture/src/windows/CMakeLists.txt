target_sources(capture PRIVATE AudioCapture.cc captureclient.cc)
target_link_libraries(capture PRIVATE samplerate)
