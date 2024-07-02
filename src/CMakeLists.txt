if(APPLE)
  add_library(addon SHARED addon.cc audiocapture.h audiocapture.cc)
  set_target_properties(addon PROPERTIES PREFIX "" SUFFIX ".node")
  set_target_properties(addon PROPERTIES LINKER_LANGUAGE CXX)
  target_link_libraries(addon ${CMAKE_JS_LIB})
  target_link_libraries(addon PRIVATE capture)
  target_link_libraries(addon PUBLIC "-framework ScreenCaptureKit" "-framework AVFoundation" "-framework Foundation")

  target_compile_definitions(addon PRIVATE NODE_API_NO_EXTERNAL_BUFFERS_ALLOWED)

  # Include Node-API wrappers
  execute_process(COMMAND node -p "require('node-addon-api').include"
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    OUTPUT_VARIABLE NODE_ADDON_API_DIR)
  string(REGEX REPLACE "[\r\n\"]" "" NODE_ADDON_API_DIR ${NODE_ADDON_API_DIR})
  target_include_directories(addon PRIVATE ${NODE_ADDON_API_DIR})
elseif(WIN32)
  # see https://github.com/cmake-js/cmake-js#important abotu CMAKE_JS_SRC.
  # On Windows, the win_delay_load_hook is required to be embedded in the
  # module or it will fail to load in the render process. cmake-js will
  # add the hook if the CMakeLists.txt contains the library ${CMAKE_JS_SRC}.
  add_library(addon SHARED addon.cc audiocapture.h audiocapture.cc ${CMAKE_JS_SRC})
  set_target_properties(addon PROPERTIES PREFIX "" SUFFIX ".node")
  set_target_properties(addon PROPERTIES LINKER_LANGUAGE CXX)
  target_link_libraries(addon PRIVATE ${CMAKE_JS_LIB})
  target_link_libraries(addon PRIVATE capture_win)
  target_compile_definitions(addon PRIVATE NODE_API_NO_EXTERNAL_BUFFERS_ALLOWED)

  # Include Node-API wrappers
  execute_process(COMMAND node -p "require('node-addon-api').include"
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    OUTPUT_VARIABLE NODE_ADDON_API_DIR)
  string(REGEX REPLACE "[\r\n\"]" "" NODE_ADDON_API_DIR ${NODE_ADDON_API_DIR})
  target_include_directories(addon PRIVATE ${NODE_ADDON_API_DIR})
else()
  message(FATAL_ERROR "unsupported platform")
endif()
