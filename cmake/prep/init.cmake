include(GNUInstallDirs)

if(NOT DEFINED PRISM_EXECUTABLE_PATH)
    set(PRISM_EXECUTABLE_PATH "prism")
endif()

if(NOT DEFINED PRISM_SESSION_DIR)
    set(PRISM_SESSION_DIR "${CMAKE_INSTALL_FULL_LIBEXECDIR}/prism"
            CACHE PATH "Installed directory containing Prism Linux session helpers")
endif()

if(PRISM_BUILD_FLATPAK)
    set(PRISM_SERVICE_START_COMMAND "ExecStart=flatpak run --command=prism ${PROJECT_FQDN}")
    set(PRISM_SERVICE_STOP_COMMAND "ExecStop=flatpak kill ${PROJECT_FQDN}")
    set(PRISM_SERVICE_CLEANUP_COMMAND "")
elseif(PRISM_BUILD_APPIMAGE)
    set(PRISM_SERVICE_START_COMMAND "ExecStart=${PRISM_EXECUTABLE_PATH}")
    set(PRISM_SERVICE_STOP_COMMAND "")
    set(PRISM_SERVICE_CLEANUP_COMMAND "ExecStopPost=${PRISM_EXECUTABLE_PATH} --internal session-cleanup")
else()
    set(PRISM_SERVICE_START_COMMAND "ExecStart=${PRISM_EXECUTABLE_PATH}")
    set(PRISM_SERVICE_STOP_COMMAND "")
    set(PRISM_SERVICE_CLEANUP_COMMAND "ExecStopPost=${PRISM_SESSION_DIR}/prism-session-cleanup.sh")
endif()
