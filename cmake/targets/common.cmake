# common target definitions
# this file will also load platform specific macros

add_executable(prism ${PRISM_TARGET_FILES})
# Prism: user-facing binary name
set_target_properties(prism PROPERTIES OUTPUT_NAME prism)
foreach(dep ${PRISM_TARGET_DEPENDENCIES})
    add_dependencies(prism ${dep})  # compile these before prism
endforeach()

# platform specific target definitions (Linux-only fork)
include(${CMAKE_MODULE_PATH}/targets/unix.cmake)
include(${CMAKE_MODULE_PATH}/targets/linux.cmake)

target_link_libraries(prism ${PRISM_EXTERNAL_LIBRARIES} ${EXTRA_LIBS})
target_compile_definitions(prism PUBLIC ${PRISM_DEFINITIONS})

# CLion complains about unknown flags after running cmake, and cannot add symbols to the index for cuda files
if(CUDA_INHERIT_COMPILE_OPTIONS)
    foreach(flag IN LISTS PRISM_COMPILE_OPTIONS)
        list(APPEND PRISM_COMPILE_OPTIONS_CUDA "$<$<COMPILE_LANGUAGE:CUDA>:--compiler-options=${flag}>")
    endforeach()
endif()

target_compile_options(prism PRIVATE $<$<COMPILE_LANGUAGE:CXX>:${PRISM_COMPILE_OPTIONS}>;$<$<COMPILE_LANGUAGE:CUDA>:${PRISM_COMPILE_OPTIONS_CUDA};-std=c++17>)  # cmake-lint: disable=C0301
target_link_options(prism PRIVATE ${PRISM_LINK_OPTIONS})

set(NPM_SOURCE_ASSETS_DIR ${PRISM_SOURCE_ASSETS_DIR})
set(NPM_ASSETS_DIR ${CMAKE_BINARY_DIR})

#WebUI build
find_program(NPM npm REQUIRED)

set(NPM_INSTALL_FLAGS "--ignore-scripts")
if (NPM_OFFLINE)
    set(NPM_INSTALL_FLAGS "${NPM_INSTALL_FLAGS} --offline")
endif()

add_custom_target(web-ui ALL
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        COMMENT "Installing NPM Dependencies and Building the Web UI"
        COMMAND "${NPM}" ci ${NPM_INSTALL_FLAGS}
        COMMAND "${CMAKE_COMMAND}" -E env "PRISM_SOURCE_ASSETS_DIR=${NPM_SOURCE_ASSETS_DIR}" "PRISM_ASSETS_DIR=${NPM_ASSETS_DIR}" "${NPM}" run build  # cmake-lint: disable=C0301
        COMMAND_EXPAND_LISTS
        VERBATIM)

# docs
if(BUILD_DOCS)
    add_subdirectory(third-party/doxyconfig docs)
endif()

# tests
if(BUILD_TESTS)
    add_subdirectory(tests)
endif()

# custom compile flags, must be after adding tests

if (NOT BUILD_TESTS)
    set(TEST_DIR "")
else()
    set(TEST_DIR "${CMAKE_SOURCE_DIR}/tests")
endif()

# src/upnp
set_source_files_properties("${CMAKE_SOURCE_DIR}/src/upnp.cpp"
        DIRECTORY "${CMAKE_SOURCE_DIR}" "${TEST_DIR}"
        PROPERTIES COMPILE_FLAGS -Wno-pedantic)

# src/nvhttp
string(TOUPPER "x${CMAKE_BUILD_TYPE}" BUILD_TYPE)
if(NOT "${BUILD_TYPE}" STREQUAL "XDEBUG")
    add_definitions(-DNDEBUG)
endif()
