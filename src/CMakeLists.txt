add_library(addon SHARED addon.cc audiocapture.h audiocapture.cc)
set_target_properties(addon PROPERTIES PREFIX "" SUFFIX ".node")
set_target_properties(addon PROPERTIES LINKER_LANGUAGE CXX)
target_link_libraries(addon ${CMAKE_JS_LIB})
target_link_libraries(addon PRIVATE capture)
target_link_libraries(addon PUBLIC "-framework ScreenCaptureKit" "-framework AVFoundation" "-framework Foundation")

# Include Node-API wrappers
execute_process(COMMAND node -p "require('node-addon-api').include"
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  OUTPUT_VARIABLE NODE_ADDON_API_DIR)
string(REGEX REPLACE "[\r\n\"]" "" NODE_ADDON_API_DIR ${NODE_ADDON_API_DIR})
target_include_directories(addon PRIVATE ${NODE_ADDON_API_DIR})
