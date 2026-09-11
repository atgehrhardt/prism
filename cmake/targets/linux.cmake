# linux specific target definitions

# Using newer c++ compilers / features on older distros causes runtime dyn link errors
list(APPEND PRISM_EXTERNAL_LIBRARIES -static-libgcc)

if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU" AND CMAKE_CXX_COMPILER_VERSION VERSION_GREATER_EQUAL 15)
    list(APPEND PRISM_EXTERNAL_LIBRARIES stdc++)
else()
    list(APPEND PRISM_EXTERNAL_LIBRARIES -static-libstdc++)
endif()

## @brief Keep the C++ compiler's runtime ahead of CUDA host compiler libraries.
## @details CMake adds CUDA's implicit library directories to mixed-language
## links. A versioned CUDA host GCC can otherwise override the newer C++
## compiler's libstdc++ and libgcc. Link options precede those generated search
## paths and are shared by Prism and test_prism. Ordinary link directories are
## insufficient because CMake removes directories implicit to the C++ compiler.
if(CUDA_FOUND AND CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    foreach(runtime_dir IN LISTS CMAKE_CXX_IMPLICIT_LINK_DIRECTORIES)
        list(APPEND PRISM_LINK_OPTIONS "$<$<LINK_LANGUAGE:CXX>:-L${runtime_dir}>")
    endforeach()
endif()
