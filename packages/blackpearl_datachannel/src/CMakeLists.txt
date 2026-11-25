# libdatachannel with data channels only (no media, no WebSocket), over Mbed TLS, linked statically into one small
# library with the shim the Dart side calls (blackpearl_datachannel.cpp). The desktop app speaks libdatachannel too
# (DataChannelDotnet), so both ends run the same ICE, DTLS and SCTP.
#
# The sources are downloaded at configure time, pinned by commit and checked by hash. libdatachannel's own submodules
# are fetched the same way, into the folders its CMakeLists expects them in. To update: change a commit (or version) and
# its hash together; the commits of plog, usrsctp and libjuice are the ones libdatachannel's tag points its submodules at
# (`git ls-tree <tag> deps/`).
cmake_minimum_required(VERSION 3.18)

project(blackpearl_datachannel LANGUAGES C CXX)

include(FetchContent)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# Options the dependencies declare with option() take the values set here.
set(CMAKE_POLICY_DEFAULT_CMP0077 NEW)

if(ANDROID)
  # With --gc-sections below, code nothing calls is left out of the library.
  string(APPEND CMAKE_C_FLAGS " -ffunction-sections -fdata-sections")
  string(APPEND CMAKE_CXX_FLAGS " -ffunction-sections -fdata-sections")
endif()

set(_bp_libdatachannel_commit 6c50b6d88fd691957f1d7df0d80875e9cd57606b) # v0.24.8
set(_bp_plog_commit 94899e0b926ac1b0f4750bfbd495167b4a6ae9ef)
set(_bp_usrsctp_commit 6a768c4618ca2442cfda21064075f84ff94c1863)
set(_bp_libjuice_commit 4fa015bb029c254443e01f1ead24360df40ceb2e)
set(_bp_mbedtls_version 3.6.8)

# Short names (mt: Mbed TLS, dc: libdatachannel, d_*: its submodules): FetchContent names its folders after them, and on
# Windows the build's paths must stay under 260 characters.
FetchContent_Declare(mt
  URL https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-${_bp_mbedtls_version}/mbedtls-${_bp_mbedtls_version}.tar.bz2
  URL_HASH SHA256=bc54b818e87f49c0b3281dd85d24adaede0e63b4e822e3fbd49c005a38b9595b
)
FetchContent_Declare(dc
  URL https://github.com/paullouisageneau/libdatachannel/archive/${_bp_libdatachannel_commit}.tar.gz
  URL_HASH SHA256=1907592c2495fca01a094eb9d9361536a7b0ee79f3cf6c28c8979ceef7e44fe3
)

# Mbed TLS: the library only, built small.
set(ENABLE_PROGRAMS OFF)
set(ENABLE_TESTING OFF)
set(GEN_FILES OFF)
set(MBEDTLS_FATAL_WARNINGS OFF)
set(USE_SHARED_MBEDTLS_LIBRARY OFF)
set(USE_STATIC_MBEDTLS_LIBRARY ON)
set(DISABLE_PACKAGE_CONFIG_AND_INSTALL ON)
# libdatachannel's DTLS transport uses Mbed TLS's DTLS-SRTP extension (to negotiate SRTP, unused for data channels),
# which Mbed TLS leaves out by default. Set for everything built after this, so Mbed TLS and libdatachannel read the
# same configuration.
add_compile_definitions(MBEDTLS_SSL_DTLS_SRTP)
FetchContent_GetProperties(mt)
if(NOT mt_POPULATED)
  FetchContent_Populate(mt)
  add_subdirectory(${mt_SOURCE_DIR} ${mt_BINARY_DIR} EXCLUDE_FROM_ALL)
endif()
# libdatachannel links MbedTLS::MbedTLS, and looks for an installed Mbed TLS only when no such target exists. An imported
# target, so libdatachannel's install rules (never run here) don't need Mbed TLS in their export set.
add_library(MbedTLS::MbedTLS INTERFACE IMPORTED)
set_target_properties(MbedTLS::MbedTLS PROPERTIES INTERFACE_LINK_LIBRARIES "mbedtls;mbedx509;mbedcrypto")

FetchContent_GetProperties(dc)
if(NOT dc_POPULATED)
  FetchContent_Populate(dc)
  # Its submodules, where its CMakeLists looks for them. libsrtp (media) and json (examples) aren't needed.
  foreach(_bp_dep plog usrsctp libjuice)
    if(_bp_dep STREQUAL "plog")
      set(_bp_url https://github.com/SergiusTheBest/plog/archive/${_bp_plog_commit}.tar.gz)
      set(_bp_hash 92a08bce559b5f28aa88d3fd9071567414b9f43a83fe2a05a6dd14f1da536072)
    elseif(_bp_dep STREQUAL "usrsctp")
      set(_bp_url https://github.com/paullouisageneau/usrsctp/archive/${_bp_usrsctp_commit}.tar.gz)
      set(_bp_hash ffa7076ee8b93d10a7048af9a45be38bf45f3b05cecfa4334c087120898be1ed)
    else()
      set(_bp_url https://github.com/paullouisageneau/libjuice/archive/${_bp_libjuice_commit}.tar.gz)
      set(_bp_hash 0178a47ffd103cc8735b8927a10af2d4ce25c2fb426b27af4bfe417b76c07485)
    endif()
    FetchContent_Declare(d_${_bp_dep}
      URL ${_bp_url}
      URL_HASH SHA256=${_bp_hash}
      SOURCE_DIR ${dc_SOURCE_DIR}/deps/${_bp_dep}
    )
    FetchContent_GetProperties(d_${_bp_dep})
    if(NOT d_${_bp_dep}_POPULATED)
      FetchContent_Populate(d_${_bp_dep})
    endif()
  endforeach()

  set(USE_MBEDTLS ON)
  set(NO_MEDIA ON)
  set(NO_WEBSOCKET ON)
  set(NO_EXAMPLES ON)
  set(NO_TESTS ON)
  set(USE_NICE OFF)
  set(PREFER_SYSTEM_LIB OFF)
  add_subdirectory(${dc_SOURCE_DIR} ${dc_BINARY_DIR} EXCLUDE_FROM_ALL)
endif()

add_library(blackpearl_datachannel SHARED blackpearl_datachannel.cpp)
target_link_libraries(blackpearl_datachannel PRIVATE LibDataChannel::LibDataChannelStatic)
target_compile_definitions(blackpearl_datachannel PRIVATE BP_DC_BUILDING=1)
set_target_properties(blackpearl_datachannel PROPERTIES
  OUTPUT_NAME "blackpearl_datachannel"
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON
)

if(ANDROID)
  target_link_libraries(blackpearl_datachannel PRIVATE log)
  # 16 KB pages (Android 15 and later), drop unused code and keep only the shim's own symbols.
  target_link_options(blackpearl_datachannel PRIVATE
    "-Wl,-z,max-page-size=16384"
    "-Wl,--gc-sections"
    "-Wl,--exclude-libs,ALL"
  )
endif()
