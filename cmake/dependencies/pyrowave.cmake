# Build the pinned standalone C API separately from Prism's CMake project.
option(PRISM_ENABLE_PYROWAVE "Build experimental PyroWave Vulkan streaming" ON)
if(PRISM_ENABLE_PYROWAVE)
    include(ExternalProject)
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    set(PYROWAVE_PREFIX "${CMAKE_BINARY_DIR}/pyrowave")
    file(MAKE_DIRECTORY "${PYROWAVE_PREFIX}/install/include/pyrowave")
    ExternalProject_Add(prism_pyrowave_build
        SOURCE_DIR "${PYROWAVE_PREFIX}/source"
        BINARY_DIR "${PYROWAVE_PREFIX}/build"
        DOWNLOAD_COMMAND ${Python3_EXECUTABLE} "${CMAKE_SOURCE_DIR}/tools/pyrowave/bootstrap.py"
                         "${PYROWAVE_PREFIX}/source"
        UPDATE_COMMAND ""
        CMAKE_ARGS -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_LIBDIR=lib
                   -DCMAKE_INSTALL_PREFIX=${PYROWAVE_PREFIX}/install
                   -DCMAKE_C_COMPILER=${CMAKE_C_COMPILER} -DCMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER}
        BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --target pyrowave-shared pyrowave-device-validation
        INSTALL_COMMAND ${CMAKE_COMMAND} --install <BINARY_DIR>
        BUILD_BYPRODUCTS "${PYROWAVE_PREFIX}/install/lib/libpyrowave-shared.so")
    add_library(prism_pyrowave SHARED IMPORTED GLOBAL)
    set_target_properties(prism_pyrowave PROPERTIES
        IMPORTED_LOCATION "${PYROWAVE_PREFIX}/install/lib/libpyrowave-shared.so"
        INTERFACE_INCLUDE_DIRECTORIES "${PYROWAVE_PREFIX}/install/include/pyrowave")
    add_dependencies(prism_pyrowave prism_pyrowave_build)
    list(APPEND PRISM_EXTERNAL_LIBRARIES prism_pyrowave)
    list(APPEND PRISM_DEFINITIONS PRISM_ENABLE_PYROWAVE)
    list(APPEND PRISM_TARGET_DEPENDENCIES prism_pyrowave_build)
    install(DIRECTORY "${PYROWAVE_PREFIX}/install/lib/" DESTINATION lib
            FILES_MATCHING PATTERN "libpyrowave-shared.so*")
    install(FILES "${PYROWAVE_PREFIX}/source/LICENSE" DESTINATION share/licenses/prism RENAME PyroWave-LICENSE)
    install(FILES "${PYROWAVE_PREFIX}/source/Granite/LICENSE" DESTINATION share/licenses/prism RENAME Granite-LICENSE)
    install(FILES "${PYROWAVE_PREFIX}/source/Granite/third_party/volk/LICENSE.md"
            DESTINATION share/licenses/prism RENAME volk-LICENSE)
    install(DIRECTORY "${PYROWAVE_PREFIX}/source/Granite/third_party/khronos/vulkan-headers/LICENSES/"
            DESTINATION share/licenses/prism/Vulkan-Headers)
    set(CMAKE_INSTALL_RPATH "$ORIGIN/../lib")
endif()
