# The Windows build is only for running the app on a PC while developing (see the app's README).
cmake_minimum_required(VERSION 3.18)

set(PROJECT_NAME "blackpearl_datachannel")
project(${PROJECT_NAME} LANGUAGES C CXX)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

set(blackpearl_datachannel_bundled_libraries
  $<TARGET_FILE:blackpearl_datachannel>
  PARENT_SCOPE
)
