# unix specific packaging

# Installation destination dir
set(CPACK_SET_DESTDIR true)
if(NOT CMAKE_INSTALL_PREFIX)
    set(CMAKE_INSTALL_PREFIX "/usr/share/prism")
endif()

install(TARGETS prism RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")
