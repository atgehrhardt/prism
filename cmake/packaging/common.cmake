# common packaging

# common cpack options
set(CPACK_PACKAGE_NAME ${CMAKE_PROJECT_NAME})
set(CPACK_PACKAGE_VENDOR "LizardByte")
set(CPACK_PACKAGE_VERSION ${PROJECT_VERSION})
set(CPACK_PACKAGE_VERSION_MAJOR ${PROJECT_VERSION_MAJOR})
set(CPACK_PACKAGE_VERSION_MINOR ${PROJECT_VERSION_MINOR})
set(CPACK_PACKAGE_VERSION_PATCH ${PROJECT_VERSION_PATCH})
set(CPACK_PACKAGE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/cpack_artifacts)
set(CPACK_PACKAGE_CONTACT "https://app.lizardbyte.dev")
set(CPACK_PACKAGE_DESCRIPTION ${CMAKE_PROJECT_DESCRIPTION})
set(CPACK_PACKAGE_HOMEPAGE_URL ${CMAKE_PROJECT_HOMEPAGE_URL})
set(CPACK_RESOURCE_FILE_LICENSE ${PROJECT_SOURCE_DIR}/LICENSE)
set(CPACK_PACKAGE_ICON ${PROJECT_SOURCE_DIR}/prism.png)
set(CPACK_PACKAGE_FILE_NAME "${CMAKE_PROJECT_NAME}")
set(CPACK_STRIP_FILES YES)

# install common assets
install(DIRECTORY "${PRISM_SOURCE_ASSETS_DIR}/common/assets/"
        DESTINATION "${PRISM_ASSETS_DIR}"
        PATTERN "web" EXCLUDE)
# copy assets to build directory, for running without install
file(GLOB_RECURSE ALL_ASSETS
        RELATIVE "${PRISM_SOURCE_ASSETS_DIR}/common/assets/" "${PRISM_SOURCE_ASSETS_DIR}/common/assets/*")
list(FILTER ALL_ASSETS EXCLUDE REGEX "^web/.*$")  # Filter out the web directory
foreach(asset ${ALL_ASSETS})  # Copy assets to build directory, excluding the web directory
    file(COPY "${PRISM_SOURCE_ASSETS_DIR}/common/assets/${asset}"
            DESTINATION "${CMAKE_CURRENT_BINARY_DIR}/assets")
endforeach()

# install built vite assets
install(DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/assets/web"
        DESTINATION "${PRISM_ASSETS_DIR}")

# platform specific packaging (Linux-only fork)
include(${CMAKE_MODULE_PATH}/packaging/unix.cmake)
include(${CMAKE_MODULE_PATH}/packaging/linux.cmake)

include(CPack)
