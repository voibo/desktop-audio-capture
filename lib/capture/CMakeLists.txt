add_library(capture STATIC Bridge.swift AudioCapture.swift)
target_link_libraries(capture PUBLIC "-framework ScreenCaptureKit" "-framework AVFoundation" "-framework Foundation")
target_compile_options(capture PUBLIC
  "$<$<COMPILE_LANGUAGE:Swift>:-cxx-interoperability-mode=default>")
