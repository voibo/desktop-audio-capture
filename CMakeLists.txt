cmake_minimum_required(VERSION 3.26)
cmake_policy(SET CMP0042 NEW)

if ((NOT APPLE) AND (NOT WIN32))
  message(FATAL_ERROR "unsupported platform")
endif()

project(desktop-audio-capture LANGUAGES CXX)

if(APPLE)
  enable_language(Swift)

  # 十分に新しいコンパイラーが存在するかどうか検証
  if("${CMAKE_Swift_COMPILER_VERSION}" VERSION_LESS 5.9)
    message(FATAL_ERROR "audio-capture-mac requires Swift 5.9 or greater. Have ${CMAKE_Swift_COMPILER_VERSION}")
  endif()

  if(NOT "${CMAKE_CXX_COMPILER_ID}" STREQUAL "Clang" AND
    NOT "${CMAKE_CXX_COMPILER_ID}" STREQUAL "AppleClang")
    message(FATAL_ERROR "Project requires building with Clang.
    Have ${CMAKE_CXX_COMPILER_ID}")
  endif()

  set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0)
endif()

set(CMAKE_CXX_STANDARD 17)

set(AUDIO_CAPTURE_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/include")
set(AUDIO_CAPTURE_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/lib")
set(AUDIO_CAPTURE_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/src")
set(AUDIO_CAPTURE_BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}")

include_directories(${CMAKE_JS_INC})
include_directories(${AUDIO_CAPTURE_INCLUDE_DIR})

add_subdirectory("${AUDIO_CAPTURE_LIB_DIR}/capture")
add_subdirectory("${AUDIO_CAPTURE_SRC_DIR}")

add_definitions(-DNAPI_VERSION=7)

if(WIN32)
  # must set BUILD_TESTING off, otherwise libsamplerate test EXEs will be
  # placed in build/Release folder
  option(BUILD_TESTING "Build the testing tree" OFF)
  add_subdirectory("${AUDIO_CAPTURE_LIB_DIR}/libsamplerate")

  if(MSVC AND CMAKE_JS_NODELIB_DEF AND CMAKE_JS_NODELIB_TARGET)
  # Generate node.lib
  execute_process(COMMAND ${CMAKE_AR} /def:${CMAKE_JS_NODELIB_DEF} /out:${CMAKE_JS_NODELIB_TARGET} ${CMAKE_STATIC_LINKER_FLAGS})
  endif()  
endif()
