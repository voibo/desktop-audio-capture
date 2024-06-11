cmake_minimum_required(VERSION 3.26)
cmake_policy(SET CMP0042 NEW)

project(audio-capture-mac LANGUAGES CXX Swift)

# 十分に新しいコンパイラーが存在するかどうか検証
if("${CMAKE_Swift_COMPILER_VERSION}" VERSION_LESS 5.9)
  message(FATAL_ERROR "audio-capture-mac requires Swift 5.9 or greater. Have ${CMAKE_Swift_COMPILER_VERSION}")
endif()

if(NOT "${CMAKE_CXX_COMPILER_ID}" STREQUAL "Clang" AND
   NOT "${CMAKE_CXX_COMPILER_ID}" STREQUAL "AppleClang")
  message(FATAL_ERROR "Project requires building with Clang.
  Have ${CMAKE_CXX_COMPILER_ID}")
endif()

set(AUDIO_CAPTURE_MAC_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/include")
set(AUDIO_CAPTURE_MAC_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/lib")
set(AUDIO_CAPTURE_MAC_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/src")
set(AUDIO_CAPTURE_MAC_BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}")

set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0)
set(CMAKE_CXX_STANDARD 17)

include_directories(${CMAKE_JS_INC})
include_directories(${AUDIO_CAPTURE_MAC_INCLUDE_DIR})

add_subdirectory("${AUDIO_CAPTURE_MAC_LIB_DIR}/capture")
add_subdirectory("${AUDIO_CAPTURE_MAC_SRC_DIR}")

add_definitions(-DNAPI_VERSION=4)
