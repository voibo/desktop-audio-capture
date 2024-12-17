add_library(capture STATIC)

if(APPLE)
  add_subdirectory(src/macos)
elseif(WIN32)
  add_subdirectory(src/windows)
endif()

