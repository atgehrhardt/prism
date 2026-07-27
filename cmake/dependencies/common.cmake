# load common dependencies
# this file will also load platform specific dependencies

# Resolve OpenSSL before subprojects run their own find_package(OpenSSL) calls.
# This ensures a user-provided OPENSSL_ROOT_DIR is honored consistently.
find_package(OpenSSL REQUIRED)

# boost, this should be before Simple-Web-Server as it also depends on boost
include(dependencies/Boost_Prism)

# submodules
# moonlight common library
set(ENET_NO_INSTALL ON CACHE BOOL "Don't install any libraries built for enet")
add_subdirectory("${CMAKE_SOURCE_DIR}/third-party/moonlight-common-c/enet")

# web server
add_subdirectory("${CMAKE_SOURCE_DIR}/third-party/Simple-Web-Server")

# lizardbyte common helpers
set(LIZARDBYTE_COMMON_BUILD_TEST_SUPPORT ${BUILD_TESTS}
        CACHE BOOL "Build lizardbyte-common GoogleTest support helpers" FORCE)
add_subdirectory("${CMAKE_SOURCE_DIR}/third-party/lizardbyte-common")

# libdisplaydevice
add_subdirectory("${CMAKE_SOURCE_DIR}/third-party/libdisplaydevice")

if(PRISM_ENABLE_TRAY)
    add_subdirectory("${CMAKE_SOURCE_DIR}/third-party/tray")
endif()

# common dependencies
include("${CMAKE_MODULE_PATH}/dependencies/nlohmann_json.cmake")
find_package(PkgConfig REQUIRED)
find_package(Threads REQUIRED)
pkg_check_modules(CURL REQUIRED libcurl)

# miniupnp
pkg_check_modules(MINIUPNP miniupnpc REQUIRED)
include_directories(SYSTEM ${MINIUPNP_INCLUDE_DIRS})

# ffmpeg pre-compiled binaries
include("${CMAKE_MODULE_PATH}/dependencies/ffmpeg.cmake")

# Opus
set(OPUS_USE_STATIC ON CACHE BOOL "Static linking for libopus")
include("${CMAKE_MODULE_PATH}/dependencies/FindOpus.cmake")

# platform specific dependencies (Linux-only fork)
include("${CMAKE_MODULE_PATH}/dependencies/unix.cmake")
include("${CMAKE_MODULE_PATH}/dependencies/linux.cmake")
